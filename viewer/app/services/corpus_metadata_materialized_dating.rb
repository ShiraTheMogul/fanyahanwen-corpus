# frozen_string_literal: true

# Reads the compact, repository-baked chronology written by
# CorpusMetadataAutoDater. These values are intentionally tiny:
#
#   "date": "1544年"          # self-referential date converted to Gregorian year
#   "ca":   "1478–1547年"    # approximate work range from author/polity
#
# Search indexes receive numeric bounds from these strings without opening CBDB
# or scanning the text at request time. Existing date_label/year metadata keeps
# its normal behaviour.
module CorpusMetadataMaterializedDating
  RANGE_DASHES = /[‐‑‒–—−-]/.freeze

  def search_metadata_for_path(rel_path)
    result = super
    metadata = document_metadata_for_path(rel_path).to_h.stringify_keys

    # Explicit numeric metadata already reached +result+ through the base store.
    # A materialized exact date comes next, then ca. Existing date_label handling
    # in HistoricalMetadataDating has already had its chance before this wrapper.
    if result["year_start"].nil? && result["year_end"].nil?
      if (bounds = materialized_date_bounds(metadata["date"]))
        result["year_start"], result["year_end"] = bounds
        result["date_text"] = metadata["date"].to_s
      elsif (bounds = materialized_ca_bounds(metadata["ca"]))
        result["year_start"], result["year_end"] = bounds
        result["date_text"] = "ca. #{metadata['ca']}"
      end
    end

    result
  end

  def display_entries_for_path(rel_path)
    entries = super
    metadata = document_metadata_for_path(rel_path).to_h.stringify_keys
    return entries if metadata["date"].to_s.strip.empty? && metadata["ca"].to_s.strip.empty?

    # Keep an older date_label visible as received metadata. The materialized
    # field is a compact search/display aid, so label it separately when both
    # exist instead of hiding the original wording.
    if metadata["date"].to_s.strip.present?
      entries << ["Gregorian date", metadata["date"].to_s.strip]
    elsif metadata["ca"].to_s.strip.present?
      entries << ["Approximate date", "ca. #{metadata['ca'].to_s.strip}"]
    end
    entries
  end

  private

  def materialized_date_bounds(value)
    text = value.to_s.strip
    return nil if text.empty?

    if (match = text.match(/\A前\s*(\d{1,4})\s*年(?:\s*\d{1,2}\s*月(?:\s*\d{1,2}\s*日)?)?\z/))
      year = -match[1].to_i
      return [year, year]
    end
    if (match = text.match(/\A(\d{1,4})\s*年(?:\s*\d{1,2}\s*月(?:\s*\d{1,2}\s*日)?)?\z/))
      year = match[1].to_i
      return [year, year]
    end
    nil
  end

  def materialized_ca_bounds(value)
    text = value.to_s.strip.sub(/\A(?:ca\.?|circa|約|约)\s*/i, "")
    return nil if text.empty?

    # Chinese compact forms used by the maintenance task.
    if (match = text.match(/\A前\s*(\d{1,4})\s*#{RANGE_DASHES.source}\s*前\s*(\d{1,4})\s*年?\z/))
      return [-match[1].to_i, -match[2].to_i].minmax
    end
    if (match = text.match(/\A前\s*(\d{1,4})\s*#{RANGE_DASHES.source}\s*(\d{1,4})\s*年?\z/))
      return [-match[1].to_i, match[2].to_i].minmax
    end
    if (match = text.match(/\A(\d{1,4})\s*#{RANGE_DASHES.source}\s*(\d{1,4})\s*年?\z/))
      return [match[1].to_i, match[2].to_i].minmax
    end
    if (match = text.match(/\A前\s*(\d{1,4})\s*年?\z/))
      year = -match[1].to_i
      return [year, year]
    end
    if (match = text.match(/\A(\d{1,4})\s*年?\z/))
      year = match[1].to_i
      return [year, year]
    end

    # Accept common imported English-era ranges too, so this reader is tolerant
    # of older metadata even though the auto-dater itself writes Chinese forms.
    normalized = text.gsub(RANGE_DASHES, "-")
    if (match = normalized.match(/\A(\d{1,4})\s*(?:BC|BCE)\s*-\s*(\d{1,4})\s*(?:BC|BCE)\s*\z/i))
      return [-match[1].to_i, -match[2].to_i].minmax
    end
    if (match = normalized.match(/\A(\d{1,4})\s*(?:BC|BCE)\s*-\s*(\d{1,4})\s*(?:AD|CE)\s*\z/i))
      return [-match[1].to_i, match[2].to_i].minmax
    end
    nil
  end
end
