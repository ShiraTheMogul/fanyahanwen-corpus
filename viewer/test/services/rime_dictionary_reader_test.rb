# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require "stringio"

class RimeDictionaryReaderTest < ActiveSupport::TestCase
  test "follows import_tables and does not import the same table twice" do
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, "root.dict.yaml"), <<~YAML)
        ---
        name: root
        import_tables:
          - root.base
          - root.extended
        ...
      YAML
      File.write(File.join(directory, "root.base.dict.yaml"), <<~YAML)
        ---
        name: root.base
        columns:
          - text
          - code
        ...
        日\ta
        明\tab
      YAML
      File.write(File.join(directory, "root.extended.dict.yaml"), <<~YAML)
        ---
        name: root.extended
        columns:
          - text
          - code
        import_tables:
          - root.base
        ...
        清\tegi
      YAML

      entries = CharacterData::RimeDictionaryReader
                .new(path: File.join(directory, "root.dict.yaml"))
                .each
                .to_a

      assert_equal ["日\ta", "明\tab", "清\tegi"], entries.map(&:line)
      assert_equal ["root.base", "root.base", "root.extended"], entries.map(&:source_table)
      assert_equal [%w[text code], %w[text code], %w[text code]], entries.map(&:columns)
    end
  end

  test "rejects unsafe sibling table names" do
    io = StringIO.new(<<~YAML)
      ---
      name: root
      import_tables:
        - ../outside
      ...
    YAML

    assert_raises(CharacterData::RimeDictionaryReader::ReadError) do
      CharacterData::RimeDictionaryReader.new(io: io).each.to_a
    end
  end
end
