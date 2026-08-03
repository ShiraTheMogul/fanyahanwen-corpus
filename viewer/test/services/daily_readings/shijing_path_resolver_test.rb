require "test_helper"
require "fileutils"
require "json"
require "tmpdir"

class DailyReadingsShijingPathResolverTest < ActiveSupport::TestCase
  SHIJING_ROOT = DailyReadings::ShijingPathResolver::DEFAULT_SHIJING_ROOT_REL
  Reading = Struct.new(:path, :order_index, :mother, :title, keyword_init: true)

  test "resolves a stale logical subgroup path through the Mao number" do
    Dir.mktmpdir do |directory|
      actual = shijing_path("小雅/桑扈之什/裳裳者華/裳裳者華.txt")
      commentary = shijing_path("小雅/桑扈之什/裳裳者華/裳裳者華_毛詩序.txt")
      write_file(directory, actual, "裳裳者華，其葉湑兮。\n")
      write_file(directory, commentary, "裳裳者華序。\n")
      write_metadata(
        directory,
        File.dirname(actual),
        title: "裳裳者華",
        mao_no: 220,
        documents: [actual, commentary]
      )

      reading = Reading.new(
        path: "小雅/甫田之什/裳裳者華/裳裳者華.txt",
        order_index: 220,
        mother: "小雅",
        title: "裳裳者華"
      )

      assert_equal actual, resolver(directory).resolve(reading)
    end
  end

  test "uses Mao number rather than an ambiguous repeated title" do
    Dir.mktmpdir do |directory|
      earlier = shijing_path("小雅/鹿鳴之什/白華/白華.txt")
      later = shijing_path("小雅/都人士之什/白華/白華.txt")

      write_file(directory, earlier, "白華菅兮。\n")
      write_file(directory, later, "白華菅兮，白茅束兮。\n")
      write_metadata(directory, File.dirname(earlier), title: "白華", mao_no: 172, documents: [earlier])
      write_metadata(directory, File.dirname(later), title: "白華", mao_no: 235, documents: [later])

      reading = Reading.new(
        path: "小雅/魚藻之什/白華/白華.txt",
        order_index: 235,
        mother: "小雅",
        title: "白華"
      )

      assert_equal later, resolver(directory).resolve(reading)
    end
  end

  test "keeps an existing stored path without requiring metadata" do
    Dir.mktmpdir do |directory|
      existing = shijing_path("國風/周南/關雎/關雎.txt")
      write_file(directory, existing, "關關雎鳩。\n")

      reading = Reading.new(
        path: "國風/周南/關雎/關雎.txt",
        order_index: 1,
        mother: "國風",
        title: "關雎"
      )

      assert_equal existing, resolver(directory).resolve(reading)
    end
  end

  private

  def resolver(directory)
    DailyReadings::ShijingPathResolver.new(corpus_root: directory, logger: nil)
  end

  def shijing_path(suffix)
    File.join(SHIJING_ROOT, suffix).tr("\\", "/")
  end

  def write_file(root, relative_path, content)
    path = File.join(root, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content, encoding: "utf-8")
  end

  def write_metadata(root, relative_directory, title:, mao_no:, documents:)
    payload = {
      "schema_version" => 1,
      "title" => title,
      "identifiers" => [{ "scheme" => "mao_no", "value" => mao_no.to_s }],
      "editions" => [
        {
          "documents" => documents.map do |document_path|
            {
              "file" => File.basename(document_path),
              "path" => document_path,
              "identifiers" => [{ "scheme" => "mao_no", "value" => mao_no.to_s }]
            }
          end
        }
      ]
    }

    path = File.join(root, relative_directory, "metadata.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(payload), encoding: "utf-8")
  end
end
