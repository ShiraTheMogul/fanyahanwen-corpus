# frozen_string_literal: true
#
# Vendored from: https://github.com/dohliam/pingyam-rb
#
# Rails adaptation:
# - Search for the database file in both Rails.root and next to this file.

class Converter
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
        method == 11 ? w : syllable
      end
    else
      word
    end
  end

  def convert_line(line, method, mods = nil)
    line_array = line.split(/\s+/)
    result = +""

    if method == 11
      11.times do |c|
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

  def to_superscript(syllable)
    num_hash = {
      "1" => "¹", "2" => "²", "3" => "³",
      "4" => "⁴", "5" => "⁵", "6" => "⁶",
      "7" => "⁷", "8" => "⁸", "9" => "⁹"
    }
    syllable.gsub!(/([1-9])/) { |d| num_hash[d] }
  end

  def normalize_yale(syllable)
    num_hash = { "7" => "1", "8" => "3", "9" => "6" }
    syllable.gsub!(/([789])/) { |d| num_hash[d] }
  end

  def get_modifications(syllable, mods)
    normalize_yale(syllable) if mods[:yale]
    to_superscript(syllable) if mods[:superscript]
    syllable
  end

  private

  def read_dict(base_rom = 0)
    candidates = []

    if defined?(Rails) && Rails.respond_to?(:root)
      candidates << Rails.root.join("pingyam", "pingyambiu").to_s
      candidates << Rails.root.join("pingyam", "pingyambiu.txt").to_s
    end

    base_dir = File.dirname(__FILE__)
    candidates << File.join(base_dir, "pingyam", "pingyambiu")
    candidates << File.join(base_dir, "pingyam", "pingyambiu.txt")

    path = candidates.find { |candidate| File.exist?(candidate) }
    unless path
      raise "Pingyam database file not found. Looked for: #{candidates.join(', ')}"
    end

    dict = {}
    File.foreach(path) do |line|
      line_split = line.chomp.split("\t")
      dict[line_split[base_rom]] = line_split
    end
    dict
  end
end
