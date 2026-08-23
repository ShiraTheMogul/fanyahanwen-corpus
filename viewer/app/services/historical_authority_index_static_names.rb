# frozen_string_literal: true

# Keep the disposable historical authority index on the same tightly bounded
# orthography rules used by the interactive resolver and auto-annotator.
#
# HistoricalAuthorityIndex.current? is called by HistoricalAuthorityStore when a
# web request checks whether the authority cache is usable. The base fingerprint
# includes CharacterEquivalenceRegistry.version_for("broad"), which asks the
# application VariantMapping table for its version. That means an ordinary era
# lookup can touch the large corpus variant graph before it has looked up an era.
#
# Authority names only need the controlled OpenCC simplified/traditional and
# Japanese shinjitai mappings. Use their file fingerprint here too. A change to
# those files still invalidates the cache, while unrelated VariantMapping edits
# no longer sit on the request path.
module HistoricalAuthorityIndexStaticNames
  private

  def source_fingerprint(snapshot)
    digest = Digest::SHA256.new
    digest << "historical-authority-v#{HistoricalAuthorityIndex::VERSION}\0"
    if HistoricalAuthorityIndex::SUPPLEMENTARY_SOURCE_PATH.file?
      digest << Digest::SHA256.file(HistoricalAuthorityIndex::SUPPLEMENTARY_SOURCE_PATH).hexdigest
    else
      digest << "no-supplementary-workbook"
    end
    digest << "\0"
    if HistoricalAuthorityIndex::CURATED_ERA_SOURCE_PATH.file?
      digest << Digest::SHA256.file(HistoricalAuthorityIndex::CURATED_ERA_SOURCE_PATH).hexdigest
    else
      digest << "no-curated-era-source"
    end
    digest << "\0"
    digest << Digest::SHA256.hexdigest(JSON.generate(snapshot || {}))
    digest << "\0"
    digest << AuthorityHanVariantRegistry.instance.version
    digest.hexdigest
  end

  # The base rebuild creates an AuthorityNameExpander for all historical names.
  # Ignore that broad-registry instance when records are actually expanded and
  # use the authority-specific registry. This keeps the rebuilt SQLite contents
  # consistent with the fingerprint above.
  def expanded_name_records(names, primary_name, _expander)
    expander = (@authority_name_expander ||= AuthorityNameExpander.new(registry: AuthorityHanVariantRegistry.instance))
    output = {}
    Array(names).map(&:to_s).map(&:strip).reject(&:empty?).uniq.each do |name|
      next unless han_name?(name)

      output[name] ||= {
        name: name,
        primary: name == primary_name,
        explicit: true,
        derivation: "explicit"
      }
      expander.expand(name).each do |form|
        output[form.name] ||= {
          name: form.name,
          primary: false,
          explicit: false,
          derivation: form.derivation
        }
      end
    end
    output.values
  end

  def write_metadata!(db, fingerprint, snapshot, counts)
    values = {
      "version" => HistoricalAuthorityIndex::VERSION.to_s,
      "fingerprint" => fingerprint,
      "built_at_utc" => Time.now.utc.iso8601,
      "supplementary_filename" => HistoricalAuthorityIndex::SUPPLEMENTARY_SOURCE_PATH.file? ? HistoricalAuthorityIndex::SUPPLEMENTARY_SOURCE_PATH.basename.to_s : "",
      "supplementary_sha256" => HistoricalAuthorityIndex::SUPPLEMENTARY_SOURCE_PATH.file? ? Digest::SHA256.file(HistoricalAuthorityIndex::SUPPLEMENTARY_SOURCE_PATH).hexdigest : "",
      "curated_era_filename" => HistoricalAuthorityIndex::CURATED_ERA_SOURCE_PATH.file? ? HistoricalAuthorityIndex::CURATED_ERA_SOURCE_PATH.basename.to_s : "",
      "curated_era_sha256" => HistoricalAuthorityIndex::CURATED_ERA_SOURCE_PATH.file? ? Digest::SHA256.file(HistoricalAuthorityIndex::CURATED_ERA_SOURCE_PATH).hexdigest : "",
      "east_asia_snapshot_version" => snapshot.to_h["version"].to_s,
      "east_asia_generated_at_utc" => snapshot.to_h["generated_at_utc"].to_s,
      "east_asia_snapshot_sha256" => Digest::SHA256.hexdigest(JSON.generate(snapshot || {})),
      "east_asia_wikidata_license" => snapshot.to_h["wikidata_license"].to_s,
      "east_asia_wikipedia_license" => snapshot.to_h["wikipedia_discovery_license"].to_s,
      "east_asia_sources_json" => JSON.generate(snapshot.to_h["sources"] || {}),
      "equivalence_version" => AuthorityHanVariantRegistry.instance.version
    }.merge(counts.transform_values(&:to_s))

    values.each do |key, value|
      db.execute("INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?)", [key, value.to_s])
    end
  end
end
