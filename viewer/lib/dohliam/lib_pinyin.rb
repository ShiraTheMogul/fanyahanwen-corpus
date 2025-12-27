# frozen_string_literal: true
#
# Vendored from: https://github.com/dohliam/pinyin-rb
#
# Rails adaptation:
# - Search for the database file in both Rails.root and next to this file.

class Py_Converter
  def initialize(base_rom = 0)
    @dict = read_dict(base_rom)
  end

  def convert_syllable(word, method, mods = nil)
    w = @dict[word.downcase]
    if w
      syllable = w[method]
      if mods
        get_modifications(syllable, mods)
      else
        method == 13 ? w : syllable
      end
    else
      word
    end
  end

  def convert_line(line, method, mods = nil)
    line_array = line.split(/\s+/)
    result = +""

    if method == 13
      13.times do |c|
        line_array.each do |word|
          result << (convert_syllable(word, c, mods) + " ")
        end
        result << "\n"
      end
    else
      line_array.each do |word|
        result << (convert_syllable(word, method, mods) + " ")
      end
    end

    result.gsub(/\s+\Z/, "")
  end

  def check_syllable(word)
    !@dict[word.downcase].nil?
  end

  def to_numerals(syllable)
    sup_hash = {
      "¹" => "1", "²" => "2", "³" => "3",
      "⁴" => "4", "⁵" => "5", "⁶" => "6",
      "⁷" => "7", "⁸" => "8", "⁹" => "9"
    }
    syllable.gsub!(/([¹²³⁴⁵⁶⁷⁸⁹])/) { |s| sup_hash[s] }
  end

  def normalize_pinyin(syllable)
    syllable.gsub!(/·/, "")
  end

  def get_modifications(syllable, mods)
    normalize_pinyin(syllable) if mods[:normalize]
    to_numerals(syllable) if mods[:numerals]
    syllable
  end

  private

  def read_dict(base_rom = 0)
    candidates = []

    if defined?(Rails) && Rails.respond_to?(:root)
      candidates << Rails.root.join("pinyin", "pinyinbiao").to_s
      candidates << Rails.root.join("pinyin", "pinyinbiao.txt").to_s
    end

    base_dir = File.dirname(__FILE__)
    candidates << File.join(base_dir, "pinyin", "pinyinbiao")
    candidates << File.join(base_dir, "pinyin", "pinyinbiao.txt")

    path = candidates.find { |candidate| File.exist?(candidate) }
    unless path
      raise "Pinyin database file not found. Looked for: #{candidates.join(', ')}"
    end

    dict = {}
    File.foreach(path) do |line|
      line_split = line.chomp.split("\t")
      dict[line_split[base_rom]] = line_split
    end
    dict
  end
end
