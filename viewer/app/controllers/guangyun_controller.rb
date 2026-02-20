# frozen_string_literal: true

class GuangyunController < ApplicationController
  # We derive the displayed rows from guangyun_payload_raw when the data fails, then split that payload into per-entry chunks keyed by the fanqie marker (two Han chars + 切).
  def index
    @counts = fetch_counts

    @query = params[:query].to_s.strip
    @codepoint = nil
    @entries = []

    return if @query.blank?

    @codepoint = find_codepoint(@query)
    return if @codepoint.nil?

    payloads = CharacterProperty
      .where(
        source: "Guangyun (Siku)",
        field: "guangyun_payload_raw",
        character_codepoint_id: @codepoint.id
      )
      .order(:id)
      .pluck(:value)

    @entries = payloads.flat_map { |payload| split_payload_into_entries(payload) }
  end

  private

  def fetch_counts
    payload_scope = CharacterProperty.where(source: "Guangyun (Siku)", field: "guangyun_payload_raw")

    {
      total_rows: CharacterProperty.where(source: "Guangyun (Siku)").count,
      characters_with_payloads: payload_scope.select(:character_codepoint_id).distinct.count,
      payload_rows: payload_scope.count,
      fanqie_rows: CharacterProperty.where(source: "Guangyun (Siku)", field: "guangyun_fanqie").count,
      definition_rows: CharacterProperty.where(source: "Guangyun (Siku)", field: "guangyun_definition").count
    }
  end

  # Accept either:
  # - a literal character (王)
  # - a Unicode codepoint string like U+738B / 0x738B / 738B
  def find_codepoint(query)
    q = query.strip

    if q.match?(/\A(?:U\+|0x)?[0-9A-Fa-f]{4,6}\z/)
      hex = q.sub(/\A(?:U\+|0x)/i, "")
      cp = hex.to_i(16)
      chr = [cp].pack("U")
      CharacterCodepoint.find_by(chr: chr)
    else
      CharacterCodepoint.find_by(chr: q[0])
    end
  rescue RangeError
    nil
  end

  # Splits a single raw payload string into 1+ aligned entries.
  #
  # Guangyun payload lines frequently contain multiple fanqie+definition blocks.
  # The safest delimiter we have *inside the payload* is the fanqie marker:
  #   two Han characters + 切
  #
  # Example:
  #   雨方切大也...又姓又雨誑切四
  # becomes two entries:
  #   fanqie=雨方切, definition=大也...又姓, raw_payload=雨方切大也...又姓
  #   fanqie=雨誑切, definition=四,           raw_payload=雨誑切四
  def split_payload_into_entries(payload)
    s = payload.to_s
      .gsub("&mdash;", "—")
      .gsub("\u00A0", " ")
      .strip

    # fanqie token = two Han chars + 切
    token_re = /[\p{Han}]{2}切/

    starts = []
    s.to_enum(:scan, token_re).each { starts << Regexp.last_match.begin(0) }

    # If we can't find a fanqie marker, still show the raw payload for inspection.
    return [{ fanqie: nil, definition: "—", raw_payload: s }] if starts.empty?

    entries = []

    starts.each_with_index do |start_idx, i|
      end_idx = (i + 1 < starts.length) ? starts[i + 1] : s.length
      chunk = s[start_idx...end_idx].to_s.strip
      next if chunk.empty?

      fanqie = chunk[0, 3]
      rest = chunk[3..].to_s.strip
      rest = rest.sub(/\A[，。、；：\s]+/, "")

      entries << {
        fanqie: fanqie,
        definition: rest.presence || "—",
        raw_payload: chunk
      }
    end

    entries
  end
end
