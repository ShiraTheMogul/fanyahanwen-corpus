require_relative "../../test_helper"

class EditTicketsMaterialMetadataTest < ActiveSupport::TestCase
  test "requires a note and at least one provenance label" do
    error = assert_raises(EditTickets::MaterialMetadata::ValidationError) do
      EditTickets::MaterialMetadata.build!({ material_note: "", provenance: [] })
    end
    assert_match(/note/i, error.message)

    error = assert_raises(EditTickets::MaterialMetadata::ValidationError) do
      EditTickets::MaterialMetadata.build!({ material_note: "A translation", provenance: [] })
    end
    assert_match(/provenance/i, error.message)
  end

  test "keeps multiple non-exclusive provenance labels" do
    metadata = EditTickets::MaterialMetadata.build!({
      material_note: "A historical translation transcribed by the submitter.",
      provenance: ["user_made", "public_domain", "historical_source", "author_provided"],
      references: "Example reference"
    })

    assert_equal %w[user_made public_domain historical_source author_provided], metadata["provenance"]
    assert_equal "Example reference", metadata["references"]
    assert_equal false, metadata["ai_assisted"]
  end

  test "requires details when AI assistance is disclosed" do
    assert_raises(EditTickets::MaterialMetadata::ValidationError) do
      EditTickets::MaterialMetadata.build!({
        material_note: "A translation",
        provenance: ["user_made"],
        ai_assisted: "1",
        ai_details: ""
      })
    end
  end
end
