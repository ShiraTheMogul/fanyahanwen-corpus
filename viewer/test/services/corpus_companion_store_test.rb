require_relative "../test_helper"
require "tmpdir"

class CorpusCompanionStoreTest < ActiveSupport::TestCase
  FakeBlob = Struct.new(:filename, :content_type, :byte_size, :contents) do
    def download
      contents
    end
  end
  FakeAttachment = Struct.new(:blob)

  test "stores companion metadata outside the corpus tree" do
    Dir.mktmpdir do |directory|
      store = CorpusCompanionStore.new(
        source_path: "朝鮮漢文/clean/朝鮮王朝/example.txt",
        storage_root: File.join(directory, "metadata"),
        public_root: File.join(directory, "public")
      )

      store.append(
        material: {
          "id" => "translation-one",
          "type" => "translation",
          "language_code" => "eng",
          "language_name" => "English",
          "translator_name" => "Example Translator",
          "note" => "Public-domain translation",
          "provenance" => %w[public_domain historical_source],
          "target_path" => "朝鮮漢文/clean/朝鮮王朝/translation/eng/translation-one/example.txt"
        }
      )

      payload = store.read
      assert_equal "朝鮮漢文/clean/朝鮮王朝/example.txt", payload["source_path"]
      assert_equal 1, payload["materials"].length
      assert_equal "eng", payload.dig("materials", 0, "language_code")
      assert_equal "Example Translator", payload.dig("materials", 0, "translator_name")
    end
  end

  test "keeps annotation systems distinct from translation languages" do
    Dir.mktmpdir do |directory|
      store = CorpusCompanionStore.new(
        source_path: "example.txt",
        storage_root: File.join(directory, "metadata"),
        public_root: File.join(directory, "public")
      )

      store.append(material: {
        "id" => "kanbun-one",
        "type" => "annotation_system",
        "annotation_system" => "kanbun",
        "note" => "Historical Kanbun annotation",
        "provenance" => %w[historical_source public_domain]
      })

      material = store.read.fetch("materials").first
      assert_equal "kanbun", material["annotation_system"]
      assert_nil material["language_code"]
    end
  end

  test "separate approved submissions accumulate for one source text" do
    Dir.mktmpdir do |directory|
      store = CorpusCompanionStore.new(
        source_path: "example.txt",
        storage_root: File.join(directory, "metadata"),
        public_root: File.join(directory, "public")
      )

      12.times do |index|
        attachment = FakeAttachment.new(FakeBlob.new("scan_#{index}.jpg", "image/jpeg", 3, index.to_s))
        store.append(
          material: { "id" => "scan-#{index}", "type" => "gallery_image", "note" => "Scan #{index}" },
          attachments: [attachment]
        )
      end

      payload = store.read
      assert_equal 12, payload["materials"].length
      assert_equal 12, Dir.glob(File.join(directory, "public", "**", "*.jpg")).length
    end
  end

  test "reapplying one ticket replaces its permanent files" do
    Dir.mktmpdir do |directory|
      store = CorpusCompanionStore.new(
        source_path: "example.txt",
        storage_root: File.join(directory, "metadata"),
        public_root: File.join(directory, "public")
      )

      first = FakeAttachment.new(FakeBlob.new("scan.jpg", "image/jpeg", 3, "one"))
      second = FakeAttachment.new(FakeBlob.new("scan.jpg", "image/jpeg", 3, "two"))

      store.append(material: { "id" => "scan-one", "type" => "gallery_image", "note" => "First" }, attachments: [first])
      store.append(material: { "id" => "scan-one", "type" => "gallery_image", "note" => "Second" }, attachments: [second])

      payload = store.read
      assert_equal 1, payload["materials"].length
      assert_equal "Second", payload.dig("materials", 0, "note")

      files = Dir.glob(File.join(directory, "public", "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }
      assert_equal 1, files.length
      assert_equal "two", File.binread(files.first)
    end
  end
  test "does not silently overwrite a corrupt manifest" do
    Dir.mktmpdir do |directory|
      store = CorpusCompanionStore.new(
        source_path: "example.txt",
        storage_root: File.join(directory, "metadata"),
        public_root: File.join(directory, "public")
      )

      storage_file = Dir.glob(File.join(directory, "metadata", "*.json")).first
      store.append(material: { "id" => "first", "type" => "gallery_image", "note" => "First" })
      storage_file = Dir.glob(File.join(directory, "metadata", "*.json")).first
      File.write(storage_file, "{broken", mode: "w:UTF-8")

      error = assert_raises(RuntimeError) do
        store.append(material: { "id" => "second", "type" => "gallery_image", "note" => "Second" })
      end
      assert_match(/Invalid companion manifest/, error.message)
      assert_equal "{broken", File.read(storage_file, encoding: "UTF-8")
    end
  end

end
