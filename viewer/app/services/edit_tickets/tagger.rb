module EditTickets
  class Tagger
    # Keep this intentionally simple and deterministic.
    # We can expand later, but avoid clever heuristics.
    def self.tags_for(source:, target_ref:, has_diff:, has_uploads:, link_count:, material_type: nil)
      tags = []
      tags << "source:#{source}" if source.present?

      if target_ref.to_s.include?("annotations")
        tags << "area:annotations"
      elsif target_ref.to_s.include?("corpus")
        tags << "area:corpus"
      elsif target_ref.to_s.include?("dict") || source.to_s.include?("dict")
        tags << "area:dictionary"
      end

      tags << "material:#{material_type}" if material_type.present?
      tags << "includes:diff" if has_diff
      tags << "includes:upload" if has_uploads
      tags << "includes:links" if link_count.to_i.positive?

      tags.uniq
    end
  end
end
