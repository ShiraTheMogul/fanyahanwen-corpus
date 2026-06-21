require_relative "../../test_helper"

class EditTicketsSubmissionExtrasTest < ActiveSupport::TestCase
  test "accepts only HTTP and HTTPS evidence links" do
    links = EditTickets::SubmissionExtras.evidence_links('["https://example.org/scan", "http://example.org/catalogue"]')
    assert_equal ["https://example.org/scan", "http://example.org/catalogue"], links

    assert_raises(EditTickets::SubmissionExtras::ValidationError) do
      EditTickets::SubmissionExtras.evidence_links("javascript:alert(1)")
    end
  end
end
