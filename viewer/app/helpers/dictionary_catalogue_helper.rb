# frozen_string_literal: true

module DictionaryCatalogueHelper
  def wfg_kangxi_entry?(entry)
    entry&.metadata.to_h["wfg"] == true
  end

  def wfg_kangxi_headword_image(entry, css_class: "dictionary-wfg-headword-image", width: 100, height: 94)
    return nil unless wfg_kangxi_entry?(entry)

    key = entry.metadata.to_h["wfg_image_key"].to_s
    return nil if key.empty?

    uri = DictionaryCatalogue::WfgKangxiResource.image_data_uri(key)
    return nil unless uri

    image_tag(
      uri,
      alt: entry.headword,
      class: css_class,
      width: width,
      height: height,
      loading: "lazy"
    )
  rescue SQLite3::Exception, Errno::ENOENT
    nil
  end

  def dictionary_character_link(form, is_pua: false)
    value = form.to_s
    return h(value) unless value.each_char.one?

    codepoint = value.ord
    if is_pua || private_use_codepoint?(codepoint)
      safe_join([
        content_tag(:span, value, class: "dictionary-pua-glyph"),
        content_tag(:small, " U+#{codepoint.to_s(16).upcase.rjust(4, '0')} (WFG local PUA)", class: "dictionary-pua-label")
      ])
    else
      link_to(
        value,
        character_path("U+#{codepoint.to_s(16).upcase.rjust(4, '0')}"),
        data: { turbo: false }
      )
    end
  end

  def wfg_location_text(label, location)
    data = location.to_h
    return nil if data.empty?

    details = []
    details << "第#{data['page']}頁" if data["page"].present?
    details << "第#{data['position']}字" if data["position"].present?
    "#{label}：#{details.join('，')}"
  end

  private

  def private_use_codepoint?(codepoint)
    codepoint.between?(0xE000, 0xF8FF) ||
      codepoint.between?(0xF0000, 0xFFFFD) ||
      codepoint.between?(0x100000, 0x10FFFD)
  end
end
