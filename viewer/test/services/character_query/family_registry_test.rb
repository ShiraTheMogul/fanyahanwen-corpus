# frozen_string_literal: true

require "test_helper"

module CharacterQuery
  class FamilyRegistryTest < ActiveSupport::TestCase
    setup do
      FamilyRegistry.reset!
      @localities = {
        "yue" => [
          { branch: "yue", collection: "xiaoxuetang", locality: "272", label: "Guangzhou",
            field: "reading.yue.xiaoxuetang_272.ipa", system_id: "topolect:yue:xiaoxuetang_272" },
          { branch: "yue", collection: "xiaoxuetang", locality: "284", label: "Xianggang(Shiqu)",
            field: "reading.yue.xiaoxuetang_284.ipa", system_id: "topolect:yue:xiaoxuetang_284" }
        ],
        "hakka" => [
          { branch: "hakka", collection: "xiaoxuetang", locality: "365", label: "Meixian(Guangdong)",
            field: "reading.hakka.xiaoxuetang_365.ipa", system_id: "topolect:hakka:xiaoxuetang_365" },
          { branch: "hakka", collection: "xiaoxuetang", locality: "373", label: "Xianggang",
            field: "reading.hakka.xiaoxuetang_373.ipa", system_id: "topolect:hakka:xiaoxuetang_373" }
        ],
        "hui" => [
          { branch: "hui", collection: "xiaoxuetang", locality: "167", label: "Tunxi(Anhuishengzhi)",
            field: "reading.hui.xiaoxuetang_167.ipa", system_id: "topolect:hui:xiaoxuetang_167" }
        ]
      }
      FamilyRegistry.instance_variable_set(:@localities, @localities)
      FamilyRegistry.instance_variable_set(:@topolect_index, nil)
    end

    teardown { FamilyRegistry.reset! }

    test "the administrative rule promotes the capital and the SAR" do
      promoted = FamilyRegistry.reference_varieties("yue").map { |entry| entry[:locality] }

      assert_includes promoted, "272"
      assert_includes promoted, "284"
    end

    test "every promoted entry carries the basis it was promoted on" do
      FamilyRegistry.reference_varieties("yue").each do |entry|
        assert entry[:basis].present?, "a promotion with no stated basis is an unsourced claim"
        assert_equal "administrative_seat", entry[:basis_kind]
      end
    end

    # Applied literally the rule promotes Hong Kong for Hakka, which is a
    # marginal Hakka area. It is suppressed rather than shipped.
    test "hakka suppresses the rule artefact and promotes nothing" do
      assert_empty FamilyRegistry.reference_varieties("hakka")
      assert FamilyRegistry.reference_varieties_absent?("hakka")
      assert FamilyRegistry.absence_reason("hakka").present?
    end

    test "a family the rule cannot reach reports an absence, not an empty list" do
      assert_empty FamilyRegistry.reference_varieties("hui")
      assert FamilyRegistry.reference_varieties_absent?("hui")
      assert FamilyRegistry.absence_reason("hui").present?
    end

    test "pinghua maps to both locale namespaces" do
      assert_equal %w[cnp csp], FamilyRegistry.locales_for("pinghua")
    end

    test "topolect systems are discovered, not hardcoded" do
      definition = FamilyRegistry.topolect_definition("topolect:yue:xiaoxuetang_272")

      assert_equal "reading.yue.xiaoxuetang_272.ipa", definition[:field]
      assert_equal :superscript_digit, definition[:tone]
      assert_equal "yue", definition[:branch]
    end
  end
end
