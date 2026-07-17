# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "pathname"
require "zip"
require_relative "../../script/folderise_singapore_flat_collections"

class SingaporeFlatCollectionFolderiserTest < Minitest::Test
  def zip_name(entry)
    name = entry.name.to_s.dup.force_encoding(Encoding::UTF_8)
    raise "invalid UTF-8 ZIP name in test" unless name.valid_encoding?

    name
  end

  def find_zip_entry(zip, wanted)
    zip.entries.find { |entry| zip_name(entry) == wanted }
  end

  def read_utf8_zip_text(entry)
    bytes = entry.get_input_stream.read.to_s.b
    text = bytes.dup.force_encoding(Encoding::UTF_8)
    raise "invalid UTF-8 ZIP body in test: #{zip_name(entry)}" unless text.valid_encoding?

    text
  end

  def find_child_metadata_entry(zip, collection)
    pattern = %r{\A新加坡漢文/clean/#{Regexp.escape(collection)}/[^/]+/metadata\.json\z}
    zip.entries.find { |entry| zip_name(entry).match?(pattern) }
  end

  def test_binary_zip_name_is_reinterpreted_as_utf8
    folderiser = SingaporeFlatCollectionFolderiser.allocate
    binary_name = "新加坡漢文/clean/名勝古跡/甲.txt".dup.force_encoding(Encoding::BINARY)

    assert_equal "新加坡漢文/clean/名勝古跡/甲.txt",
      folderiser.send(:normalize_zip_name, binary_name)
  end
  def test_archive_to_archive_folderisation_preserves_full_title_and_body
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      source_zip = root.join("source.zip")
      output_root = root.join("output")
      output_zip = output_root.join("repaired.zip")
      title = "這是一個故意很長很長很長很長很長很長很長很長的完整作品標題"
      body = "第一句。\n第二句。\n"

      Zip::File.open(source_zip.to_s, create: true) do |zip|
        %w[新加坡漢文/ 新加坡漢文/clean/ 新加坡漢文/clean/名勝古跡/ 新加坡漢文/clean/新洲雅苑懷舊集/].each do |name|
          zip.mkdir(name)
        end
        zip.get_output_stream("新加坡漢文/clean/名勝古跡/#{title}.txt") do |io|
          io.write("# TITLE: #{title}\n# AUTHOR: 測試作者\n# NATION: 新加坡\n# SOURCE: 測試來源\n\n#{body}")
        end
        zip.get_output_stream("新加坡漢文/clean/新洲雅苑懷舊集/短題.txt") do |io|
          io.write("# TITLE: 短題\n# AUTHOR: 另一作者\n# NATION: 新加坡\n# SOURCE: 另一來源\n\n正文。\n")
        end
      end

      options = {
        source_zip: source_zip.to_s,
        corpus_root: nil,
        output_root: output_root.to_s,
        output_zip: output_zip.to_s,
        apply: true,
        replan: true,
        extract_tree: true,
        max_title_chars: 18,
        work_id_start: 900_001,
        document_id_start: 1_800_001,
        read_retries: 1,
        progress_every: 0,
        targets: SingaporeFlatCollectionFolderiser::TARGETS
      }

      SingaporeFlatCollectionFolderiser.new(options).run

      assert output_zip.file?
      assert_equal [0xEF, 0xBB, 0xBF], File.binread(output_root.join("folderisation_plan.csv"), 3).bytes
      Zip::File.open(output_zip.to_s) do |zip|
        flat = zip.entries.select do |entry|
          zip_name(entry).match?(%r{\A新加坡漢文/clean/(?:名勝古跡|新洲雅苑懷舊集)/[^/]+\.txt\z})
        end
        assert_empty flat

        child_metadata_entry = find_child_metadata_entry(zip, "名勝古跡")
        refute_nil child_metadata_entry
        metadata = JSON.parse(read_utf8_zip_text(child_metadata_entry))
        assert_equal title, metadata.fetch("title")
        assert_equal ["測試作者"], metadata.fetch("authors")

        text_path = metadata.fetch("editions").first.fetch("documents").first.fetch("path")
        assert_equal body, read_utf8_zip_text(find_zip_entry(zip, text_path))
        assert_equal "text.txt", File.basename(text_path)
        assert_operator File.basename(File.dirname(text_path)).bytesize, :<=, 180
      end
    end
  end
  def test_archive_without_explicit_directory_entries_is_accepted
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      source_zip = root.join("source_without_directories.zip")
      output_root = root.join("output")
      output_zip = output_root.join("repaired.zip")

      Zip::File.open(source_zip.to_s, create: true) do |zip|
        zip.get_output_stream("新加坡漢文/clean/名勝古跡/甲.txt") do |io|
          io.write("# TITLE: 甲\n# AUTHOR: 甲作者\n# NATION: 新加坡\n# SOURCE: 甲來源\n\n甲文。\n")
        end
        zip.get_output_stream("新加坡漢文/clean/新洲雅苑懷舊集/乙.txt") do |io|
          io.write("# TITLE: 乙\n# AUTHOR: 乙作者\n# NATION: 新加坡\n# SOURCE: 乙來源\n\n乙文。\n")
        end
      end

      Zip::File.open(source_zip.to_s) do |zip|
        assert_nil find_zip_entry(zip, "新加坡漢文/clean/")
        assert_nil find_zip_entry(zip, "新加坡漢文/clean/名勝古跡/")
      end

      options = {
        source_zip: source_zip.to_s,
        corpus_root: nil,
        output_root: output_root.to_s,
        output_zip: output_zip.to_s,
        apply: true,
        replan: true,
        extract_tree: true,
        max_title_chars: 18,
        work_id_start: 910_001,
        document_id_start: 1_810_001,
        read_retries: 1,
        progress_every: 0,
        targets: SingaporeFlatCollectionFolderiser::TARGETS
      }

      SingaporeFlatCollectionFolderiser.new(options).run

      assert output_zip.file?
      Zip::File.open(output_zip.to_s) do |zip|
        refute_nil find_zip_entry(zip, "新加坡漢文/clean/名勝古跡/metadata.json")
        refute_nil find_zip_entry(zip, "新加坡漢文/clean/新洲雅苑懷舊集/metadata.json")
      end
    end
  end

  def test_invalid_utf8_is_audited_and_requires_explicit_apply_acceptance
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      source_zip = root.join("source_invalid_utf8.zip")
      output_root = root.join("output")
      output_zip = output_root.join("repaired.zip")

      Zip::File.open(source_zip.to_s, create: true) do |zip|
        zip.get_output_stream("新加坡漢文/clean/名勝古跡/甲.txt") do |io|
          io.write("# TITLE: 甲\n# AUTHOR: 甲作者\n# NATION: 新加坡\n# SOURCE: 甲來源\n\n正文。\n".b + "\xA5".b)
        end
        zip.get_output_stream("新加坡漢文/clean/新洲雅苑懷舊集/乙.txt") do |io|
          io.write("# TITLE: 乙\n# AUTHOR: 乙作者\n# NATION: 新加坡\n# SOURCE: 乙來源\n\n乙文。\n")
        end
      end

      base_options = {
        source_zip: source_zip.to_s,
        corpus_root: nil,
        output_root: output_root.to_s,
        output_zip: output_zip.to_s,
        apply: false,
        replan: true,
        extract_tree: true,
        max_title_chars: 18,
        work_id_start: 920_001,
        document_id_start: 1_820_001,
        read_retries: 1,
        progress_every: 0,
        targets: SingaporeFlatCollectionFolderiser::TARGETS
      }

      SingaporeFlatCollectionFolderiser.new(base_options).run
      repairs = CSV.read(output_root.join("encoding_repairs.csv"), headers: true)
      assert_equal 1, repairs.length
      assert_equal "A5", repairs.first["invalid_bytes_hex"]

      error = assert_raises(ArgumentError) do
        SingaporeFlatCollectionFolderiser.new(base_options.merge(apply: true, replan: false)).run
      end
      assert_match(/--accept-utf8-repairs/, error.message)

      SingaporeFlatCollectionFolderiser.new(
        base_options.merge(apply: true, replan: false, accept_utf8_repairs: true)
      ).run
      assert output_zip.file?

      Zip::File.open(output_zip.to_s) do |zip|
        metadata_entry = find_child_metadata_entry(zip, "名勝古跡")
        metadata = JSON.parse(read_utf8_zip_text(metadata_entry))
        text_path = metadata.fetch("editions").first.fetch("documents").first.fetch("path")
        assert_equal "正文。\n", read_utf8_zip_text(find_zip_entry(zip, text_path))
      end
    end
  end

end
