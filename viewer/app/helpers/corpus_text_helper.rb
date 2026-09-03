# frozen_string_literal: true

module CorpusTextHelper
  include PhoneticizationHelper

  def corpus_text_with_optional_ruby(text, allow_ruby: true)
  s = text.to_s
  @__chengyu_text_marks = chengyu_text_marks_for(s)
  @__hidden_source_comment_indices = source_comment_line_indices(s)

  # Always render indexed spans so client-side annotations can map selections
  # back to corpus character offsets. Hash-prefixed provenance lines stay in
  # those offsets but are hidden from the reader display.
  if allow_ruby && ruby_enabled_in_session?
    corpus_text_with_ruby_indexed(s)
  else
    corpus_text_without_ruby_indexed(s)
  end
ensure
  @__chengyu_text_marks = nil
  @__hidden_source_comment_indices = nil
end

private

  # Kanripo and some older imports place source/provenance notes in the body as
  # lines beginning with '#'. Keep them in the stored text and character index;
  # the Corpus Viewer only suppresses their visual rendering.
  def source_comment_line_indices(text)
    hidden = {}
    index = 0

    text.to_s.each_line do |line|
      length = line.each_char.count
      length.times { |offset| hidden[index + offset] = true } if line.start_with?("#")
      index += length
    end

    hidden
  end

  def hidden_source_comment_index?(index)
    @__hidden_source_comment_indices&.key?(index)
  end

  def append_hidden_source_character(buf, character, index)
    buf.safe_concat(%(<span class="cch corpus-source-comment" data-corpus-idx="#{index}" hidden aria-hidden="true">).html_safe)
    buf << ERB::Util.html_escape(character)
    buf.safe_concat("</span>".html_safe)
  end


  def chengyu_text_marks_for(display_text)
    return {} unless defined?(@active_text_target_path) && @active_text_target_path.present?
    return {} unless defined?(ChengyuForm) && ChengyuForm.table_exists? && ChengyuForm.exists?

    raw = defined?(@raw_body) ? @raw_body.to_s : display_text.to_s
    offsets_compatible = raw.each_char.count == display_text.to_s.each_char.count
    # Possible-usage matching can use the displayed script. Confirmed source
    # offsets, however, were derived from the stored corpus text, so only apply
    # them when script conversion has preserved one display character per source
    # character.
    source_text = offsets_compatible ? raw : display_text.to_s

    source_view = !defined?(@display_translation) || @display_translation.blank?
    source_view &&= !defined?(@display_annotation_system) || @display_annotation_system.blank?

    if source_view && offsets_compatible && defined?(@work_folder_view) && @work_folder_view && defined?(@work_document_paths)
      return ChengyuData::TextHighlights.new(
        text: source_text,
        document_paths: @work_document_paths,
        corpus_root: Rails.configuration.x.corpus_root
      ).marks
    end

    confirmed_path = nil
    if source_view && offsets_compatible && defined?(@source_rel_path) && @active_text_target_path.to_s == @source_rel_path.to_s
      confirmed_path = @source_rel_path
    end

    ChengyuData::TextHighlights.new(text: source_text, document_path: confirmed_path).marks
  rescue ActiveRecord::StatementInvalid, NameError
    {}
  end

  def chengyu_classes_and_attributes(index, classes)
    mark = @__chengyu_text_marks&.fetch(index, nil)
    return [classes, ""] unless mark

    possible = mark[:possible].present?
    confirmed = mark[:confirmed].present?
    classes << "chengyu-possible-use" if possible
    classes << "chengyu-confirmed-source" if confirmed

    attributes = []
    if mark[:anchor_id].present?
      attributes << %(id="#{ERB::Util.html_escape(mark[:anchor_id])}")
    end

    title = if confirmed
      "Recorded Chengyu source context: #{Array(mark[:confirmed]).join(' / ')}"
    elsif possible
      "Known Chengyu form occurs here: #{mark[:possible].to_a.join(' / ')}"
    end
    attributes << %(title="#{ERB::Util.html_escape(title)}") if title.present?

    [classes, attributes.empty? ? "" : " #{attributes.join(' ')}"]
  end

  def ruby_enabled_in_session?
    v = session[:ruby_enabled]
    v == true || v.to_s == "true" || v.to_s == "1"
  end

  def current_ruby_source_sym
    (session[:ruby_source].presence || :mandarin).to_s.strip.downcase.tr(" ", "_").to_sym
  end

  def current_ruby_orientation_sym
    raw = session[:ruby_orientation].presence || :horizontal
    sym = raw.to_s.strip.downcase.to_sym
    sym = :vertical if sym == :verticalside
    [:horizontal, :vertical].include?(sym) ? sym : :horizontal
  end

  def current_ruby_side_sym
    raw = session[:ruby_side].presence || :right
    sym = raw.to_s.strip.downcase.to_sym
    [:right, :left].include?(sym) ? sym : :right
  end

  def corpus_ruby_class
    parts = ["ruby-annot", "ruby-#{current_ruby_orientation_sym}"]
    parts << "ruby-side-#{current_ruby_side_sym}" if current_ruby_orientation_sym == :vertical
    parts.join(" ")
  end

  def unique_han_chars(text)
    seen = {}
    text.each_char do |ch|
      next unless ch.match?(/\p{Han}/)
      seen[ch] = true
    end
    seen.keys
  end

  def format_ruby_token(entry, tok)
    case entry[:formatter]
    when :mandarin, :cantonese
      phoneticize_unihan_value(entry[:field], tok)
    when :japanese_kana
      return tok if tok.match?(/[\p{Hiragana}\p{Katakana}]/)
      respond_to?(:hepburn_to_kana, true) ? hepburn_to_kana(tok) : tok
    when :korean_hangul
      tok.to_s.sub(/[：:].*$/, "").strip
    when :bs2014_oc
      tok.to_s.gsub(/[\[\]]/, "").strip
    else
      tok
    end
  rescue StandardError
    tok
  end

  def laoguoyin_reading_map(ids_by_chr, ids)
    scheme = current_laoguoyin_scheme rescue :latin

    rows = []
    ids.each_slice(500) do |id_slice|
      rows.concat(
        LaoguoyinReading.where(character_codepoint_id: id_slice)
                        .pluck(:character_codepoint_id, :laoguoyin, :zhuyin, :ipa)
      )
    end

    best = {}
    rows.each do |cid, latin, zhuyin, ipa|
      next if best.key?(cid)

      parts = []
      parts << latin.to_s.strip if latin.present?
      parts << zhuyin.to_s.strip if zhuyin.present?
      if ipa.present?
        ipa_s = ipa.to_s.strip
        ipa_s = "/#{ipa_s}/" unless ipa_s.start_with?("/")
        parts << ipa_s
      end

      raw = parts.join(" ")
      best[cid] = format_laoguoyin_value(raw, scheme: scheme)
    end

    out = {}
    ids_by_chr.each do |chr, cid|
      out[chr] = best[cid] if best[cid].present?
    end

    out
  rescue StandardError
    {}
  end
  def corpus_ruby_readings_for(chars)
    entry = PronunciationRegistry.ruby_source(current_ruby_source_sym)
    return {} unless entry

    # Avoid DB parameter limits (SQLite famously caps at 999).
    ids_by_chr = {}
    chars.each_slice(500) do |slice|
      ids_by_chr.merge!(CharacterCodepoint.where(chr: slice).pluck(:chr, :id).to_h)
    end
    return {} if ids_by_chr.empty?

    ids = ids_by_chr.values
    if entry[:special] == :laoguoyin
      return laoguoyin_reading_map(ids_by_chr, ids)
    end

    rows = []
    ids.each_slice(500) do |id_slice|
      relation = CharacterProperty.where(
        character_codepoint_id: id_slice,
        field: entry[:field]
      )
      relation = relation.where(source: entry[:sources]) if entry[:sources].any?
      rows.concat(relation.pluck(:character_codepoint_id, :source, :value))
    end

    source_rank = entry[:sources].each_with_index.to_h
    best_value = {}
    rows.sort_by { |cid, source, _value| [cid, source_rank.fetch(source.to_s, 999)] }.each do |cid, _source, value|
      best_value[cid] ||= value
    end

    ids_by_chr.each_with_object({}) do |(chr, cid), output|
      raw = best_value[cid].to_s
      token = raw.strip.split(/\s+/).reject(&:blank?).first
      next if token.blank?

      output[chr] = format_ruby_token(entry, token)
    end
  rescue StandardError
    {}
  end



  # Render text as HTML where each original character is wrapped with a span:
#   <span class="cch" data-corpus-idx="123">字</span>
#
# This makes it possible to store user annotations in terms of character
# offsets and later re-apply them reliably, even when ruby <rt> tags exist.
#
# Notes (〔〕, {}, 〈〉, []) are wrapped in a container so CSS can render them
# smaller and (optionally) multi-column.
def corpus_text_without_ruby_indexed(text)
  buf = ActiveSupport::SafeBuffer.new
  idx = 0

  note_stack = []

  text.each_char do |ch|
    if hidden_source_comment_index?(idx)
      append_hidden_source_character(buf, ch, idx)
      idx += 1
      next
    end

    opener = note_opener_kind(ch)
    closer = note_closer_kind(ch)

    if opener
      note_stack << opener
      buf.safe_concat(%(<span class="corpus-note-block corpus-note-#{opener}" data-note-kind="#{opener}">).html_safe)
    end
    classes = ["cch"]
    classes << "note-bracket" if opener || closer
    classes << "kanbun-annotation-mark" if kanbun_annotation_mark?(ch)
    classes, chengyu_attributes = chengyu_classes_and_attributes(idx, classes)

    buf.safe_concat(%(<span class="#{classes.join(" ")}" data-corpus-idx="#{idx}"#{chengyu_attributes}>).html_safe)
    buf << ERB::Util.html_escape(ch)
    buf.safe_concat("</span>".html_safe)

    if closer && note_stack.any?
      note_stack.pop
      buf.safe_concat("</span>".html_safe)
    end

    idx += 1
  end

  buf
end

def corpus_text_with_ruby_indexed(text)
  chars = unique_han_chars(text)
  return corpus_text_without_ruby_indexed(text) if chars.empty?

  readings = corpus_ruby_readings_for(chars)
  ruby_class = corpus_ruby_class

  buf = ActiveSupport::SafeBuffer.new
  idx = 0
  note_stack = []

  text.each_char do |ch|
    if hidden_source_comment_index?(idx)
      append_hidden_source_character(buf, ch, idx)
      idx += 1
      next
    end

    opener = note_opener_kind(ch)
    closer = note_closer_kind(ch)

    if opener
      note_stack << opener
      buf.safe_concat(%(<span class="corpus-note-block corpus-note-#{opener}" data-note-kind="#{opener}">).html_safe)
    end
    classes = ["cch"]
    classes << "note-bracket" if opener || closer
    classes << "kanbun-annotation-mark" if kanbun_annotation_mark?(ch)
    classes, chengyu_attributes = chengyu_classes_and_attributes(idx, classes)

    reading = readings[ch]
    if reading.present?
      buf.safe_concat(%(<ruby class="#{ruby_class}">).html_safe)

      buf.safe_concat(%(<span class="#{classes.join(" ")}" data-corpus-idx="#{idx}"#{chengyu_attributes}>).html_safe)
      buf << ERB::Util.html_escape(ch)
      buf.safe_concat("</span>".html_safe)
      buf.safe_concat("<rt>".html_safe)
      buf << ERB::Util.html_escape(reading)
      buf.safe_concat("</rt></ruby>".html_safe)
    else
      buf.safe_concat(%(<span class="#{classes.join(" ")}" data-corpus-idx="#{idx}"#{chengyu_attributes}>).html_safe)
      buf << ERB::Util.html_escape(ch)
      buf.safe_concat("</span>".html_safe)
    end

    if closer && note_stack.any?
      note_stack.pop
      buf.safe_concat("</span>".html_safe)
    end

    idx += 1
  end

  buf
end


def kanbun_annotation_mark?(ch)
  codepoint = ch.to_s.ord
  codepoint >= 0x3190 && codepoint <= 0x319F
rescue StandardError
  false
end

NOTE_OPENERS = {
  "〔" => :fang,
  "{"  => :brace,
  "〈" => :angle,
  "["  => :square
}.freeze

NOTE_CLOSERS = {
  "〕" => :fang,
  "}"  => :brace,
  "〉" => :angle,
  "]"  => :square
}.freeze

def note_opener_kind(ch)
  NOTE_OPENERS[ch]
end

def note_closer_kind(ch)
  NOTE_CLOSERS[ch]
end

end
