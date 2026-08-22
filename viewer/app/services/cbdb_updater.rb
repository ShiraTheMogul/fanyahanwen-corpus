# frozen_string_literal: true

require "date"
require "digest"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "pathname"
require "securerandom"
require "time"
require "uri"

# Maintains the local CBDB SQLite source in viewer/data without committing the
# database itself. A light release record lives in the existing corpus-search
# cache, while the SQLite source remains a replaceable external dependency.
class CbdbUpdater
  REMOTE_URL = "https://huggingface.co/datasets/cbdb/cbdb-sqlite/resolve/main/latest.zip"
  RELEASE_CACHE_PATH = "cbdb-release-v1.json.gz"
  USER_AGENT = "FanyaHanwenCorpus/1.0 (CBDB authority maintenance)"
  DATA_GLOB = "cbdb*.sqlite3"

  LocalRelease = Data.define(:sqlite_path, :release, :message) do
    def available? = sqlite_path.present? && File.file?(sqlite_path)
  end

  Result = Data.define(:status, :sqlite_path, :release, :message) do
    def available? = sqlite_path.present? && File.file?(sqlite_path)
    def updated? = status == :updated
  end

  def self.refresh_if_needed!(cache_store: CorpusSearch::CacheStore.new, force: false, logger: Rails.logger)
    new(cache_store: cache_store, logger: logger).refresh_if_needed!(force: force)
  end

  def self.current_local(cache_store: CorpusSearch::CacheStore.new)
    new(cache_store: cache_store, logger: nil).current_local
  end

  def self.verify_local!(cache_store: CorpusSearch::CacheStore.new)
    new(cache_store: cache_store, logger: nil).verify_local!
  end

  def initialize(cache_store:, logger: nil)
    @cache_store = cache_store
    @logger = logger
    @data_root = Rails.root.join("data")
  end

  def current_local
    path = local_sqlite_paths.max_by { |candidate| local_sort_key(candidate) }
    return nil unless path

    release = @cache_store.read_json(RELEASE_CACHE_PATH).to_h
    sha = if release["sqlite_filename"].to_s == path.basename.to_s && release["sha256"].present?
      release["sha256"].to_s
    else
      Digest::SHA256.file(path).hexdigest
    end
    release = release.merge(
      "sqlite_filename" => path.basename.to_s,
      "sha256" => sha
    )
    LocalRelease.new(sqlite_path: path.to_s, release: release, message: "Using local #{path.basename}.")
  rescue SystemCallError
    nil
  end

  def refresh_if_needed!(force: false)
    FileUtils.mkdir_p(@data_root)
    local = current_local
    remote = remote_metadata

    if local&.available? && !force && remote_not_newer?(local, remote)
      release = adopt_remote_metadata(local, remote)
      return Result.new(
        status: :current,
        sqlite_path: local.sqlite_path,
        release: release,
        message: "CBDB #{File.basename(local.sqlite_path)} is current."
      )
    end

    download_and_install!(remote)
  rescue StandardError => e
    @logger&.warn("[cbdb] refresh failed: #{e.class}: #{e.message}")
    if local&.available?
      Result.new(
        status: :stale,
        sqlite_path: local.sqlite_path,
        release: local.release,
        message: "CBDB refresh failed; keeping #{File.basename(local.sqlite_path)} (#{e.class}: #{e.message})."
      )
    else
      Result.new(status: :unavailable, sqlite_path: nil, release: {}, message: "CBDB is unavailable: #{e.class}: #{e.message}")
    end
  end

  def verify_local!
    local = current_local
    return Result.new(status: :unavailable, sqlite_path: nil, release: {}, message: "No local CBDB SQLite database found under #{@data_root}.") unless local&.available?

    require "sqlite3"
    db = SQLite3::Database.new(local.sqlite_path, readonly: true)
    quick_check = db.get_first_value("PRAGMA quick_check").to_s
    raise "SQLite quick_check returned #{quick_check.inspect}" unless quick_check == "ok"
    raise "NIAN_HAO table is missing" unless table_exists?(db, "NIAN_HAO")
    raise "BIOG_MAIN table is missing" unless table_exists?(db, "BIOG_MAIN")

    sha = Digest::SHA256.file(local.sqlite_path).hexdigest
    release = local.release.merge("sha256" => sha, "sqlite_filename" => File.basename(local.sqlite_path))
    @cache_store.write_json(RELEASE_CACHE_PATH, release)
    Result.new(
      status: :verified,
      sqlite_path: local.sqlite_path,
      release: release,
      message: "Verified #{File.basename(local.sqlite_path)} (SHA-256 and SQLite quick_check)."
    )
  ensure
    db&.close
  end

  private

  def local_sqlite_paths
    Dir.glob(@data_root.join(DATA_GLOB).to_s).filter_map do |value|
      path = Pathname(value)
      path if path.file?
    end
  end

  def local_sort_key(path)
    date = basename_date(path.basename.to_s)
    [date || Date.new(1, 1, 1), path.mtime]
  rescue SystemCallError
    [Date.new(1, 1, 1), Time.at(0)]
  end

  def basename_date(filename)
    match = filename.match(/(20\d{6})/)
    Date.strptime(match[1], "%Y%m%d") if match
  rescue Date::Error
    nil
  end

  def remote_not_newer?(local, remote)
    cached = @cache_store.read_json(RELEASE_CACHE_PATH).to_h
    local_sha = Digest::SHA256.file(local.sqlite_path).hexdigest
    if cached["sha256"].to_s == local_sha && cached["remote_etag"].present? && remote["etag"].present?
      return true if cached["remote_etag"].to_s == remote["etag"].to_s
    end

    local_date = basename_date(File.basename(local.sqlite_path))
    remote_date = remote["last_modified_date"] && Date.iso8601(remote["last_modified_date"])
    local_date && remote_date && local_date >= remote_date
  rescue Date::Error, SystemCallError
    false
  end

  def adopt_remote_metadata(local, remote)
    release = {
      "version" => 1,
      "sqlite_filename" => File.basename(local.sqlite_path),
      "sha256" => Digest::SHA256.file(local.sqlite_path).hexdigest,
      "remote_url" => REMOTE_URL,
      "remote_etag" => remote["etag"].to_s,
      "remote_last_modified" => remote["last_modified"].to_s,
      "checked_at_utc" => Time.now.utc.iso8601,
      "generated_at_utc" => local.release["generated_at_utc"].to_s.presence
    }.compact
    @cache_store.write_json(RELEASE_CACHE_PATH, release)
    release
  end

  def remote_metadata
    uri = URI(REMOTE_URL)
    response, final_uri = request_following_redirects(uri, method: :head)
    if response.code.to_i == 405 || response.code.to_i == 403
      response, final_uri = request_following_redirects(uri, method: :get, range: "bytes=0-0")
    end
    unless response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPPartialContent)
      raise "HTTP #{response.code} while checking CBDB"
    end

    last_modified = response["Last-Modified"].to_s
    parsed = Time.httpdate(last_modified) unless last_modified.empty?
    {
      "etag" => response["ETag"].to_s,
      "last_modified" => last_modified,
      "last_modified_date" => parsed&.to_date&.iso8601,
      "resolved_url" => final_uri.to_s
    }.compact
  rescue ArgumentError
    { "resolved_url" => REMOTE_URL }
  end

  def download_and_install!(remote)
    directory = @cache_store.absolute("cbdb-download")
    FileUtils.mkdir_p(directory)
    token = "#{Process.pid}-#{SecureRandom.hex(5)}"
    zip_path = directory.join("latest-#{token}.zip")
    extract_path = directory.join("extract-#{token}")
    FileUtils.mkdir_p(extract_path)

    download_file(URI(REMOTE_URL), zip_path)
    unzip!(zip_path, extract_path)
    sqlite = Dir.glob(extract_path.join("**", "*.sqlite3").to_s).map { |value| Pathname(value) }.max_by(&:size)
    raise "CBDB latest.zip did not contain a SQLite database" unless sqlite&.file?

    require "sqlite3"
    db = SQLite3::Database.new(sqlite.to_s, readonly: true)
    raise "Downloaded CBDB SQLite failed quick_check" unless db.get_first_value("PRAGMA quick_check").to_s == "ok"
    raise "Downloaded database does not contain NIAN_HAO" unless table_exists?(db, "NIAN_HAO")
    db.close
    db = nil

    internal_name = sqlite.basename.to_s
    if internal_name.match?(/\Acbdb.*\.sqlite3\z/i)
      target = @data_root.join(internal_name)
    else
      release_date = remote["last_modified_date"].to_s.delete("-")
      release_date = Time.now.utc.strftime("%Y%m%d") unless release_date.match?(/\A\d{8}\z/)
      target = @data_root.join("cbdb_#{release_date}.sqlite3")
    end
    temp_target = @data_root.join(".#{target.basename}.#{token}.tmp")
    FileUtils.cp(sqlite, temp_target)
    File.rename(temp_target, target)

    sha = Digest::SHA256.file(target).hexdigest
    release = {
      "version" => 1,
      "sqlite_filename" => target.basename.to_s,
      "sha256" => sha,
      "remote_url" => REMOTE_URL,
      "remote_etag" => remote["etag"].to_s,
      "remote_last_modified" => remote["last_modified"].to_s,
      "checked_at_utc" => Time.now.utc.iso8601,
      "generated_at_utc" => remote["last_modified"].to_s
    }
    @cache_store.write_json(RELEASE_CACHE_PATH, release)

    Result.new(status: :updated, sqlite_path: target.to_s, release: release, message: "Downloaded and verified #{target.basename}.")
  ensure
    db&.close rescue nil
    FileUtils.rm_f(temp_target) if defined?(temp_target) && temp_target
    FileUtils.rm_f(zip_path) if defined?(zip_path) && zip_path
    FileUtils.rm_rf(extract_path) if defined?(extract_path) && extract_path
  end

  def unzip!(zip_path, destination)
    stdout, status = Open3.capture2e("unzip", "-q", "-o", zip_path.to_s, "-d", destination.to_s)
    raise "unzip failed: #{stdout}" unless status.success?
  rescue Errno::ENOENT
    raise "The system 'unzip' command is required to extract CBDB latest.zip"
  end

  def download_file(uri, path, limit: 8)
    raise "too many CBDB download redirects" if limit <= 0

    response, final_uri = request_following_redirects(uri, method: :get, limit: limit, stream_to: path)
    unless response.is_a?(Net::HTTPSuccess)
      raise "HTTP #{response.code} while downloading CBDB from #{final_uri.host}"
    end
    path
  end

  def request_following_redirects(uri, method:, limit: 8, range: nil, stream_to: nil)
    raise "too many redirects" if limit <= 0

    klass = method == :head ? Net::HTTP::Head : Net::HTTP::Get
    req = klass.new(uri)
    req["User-Agent"] = USER_AGENT
    req["Accept"] = method == :head ? "*/*" : "application/octet-stream"
    req["Range"] = range if range

    response = nil
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 20, read_timeout: 180) do |http|
      if stream_to && method == :get
        http.request(req) do |res|
          response = res
          if res.is_a?(Net::HTTPSuccess)
            File.open(stream_to, "wb") { |file| res.read_body { |chunk| file.write(chunk) } }
          end
        end
      else
        response = http.request(req)
      end
    end

    if response.is_a?(Net::HTTPRedirection)
      target = URI.join(uri.to_s, response.fetch("location"))
      return request_following_redirects(target, method: method, limit: limit - 1, range: range, stream_to: stream_to)
    end
    [response, uri]
  end

  def table_exists?(db, table_name)
    db.get_first_value("SELECT 1 FROM sqlite_master WHERE type='table' AND name = ? LIMIT 1", [table_name]).to_i == 1
  end
end
