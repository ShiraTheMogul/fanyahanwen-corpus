require_relative "../test_helper"

class IdsParserTest < ActiveSupport::TestCase
  test "parses binary IDS and returns leaves in reading order" do
    tree = Ids::Parser.parse("⿰氵青")

    assert_equal "⿰", tree.token
    assert_equal %w[氵 青], Ids::Parser.leaves(tree)
    assert_equal ["⿰"], Ids::Parser.operators(tree)
  end

  test "supports modern unary and ternary IDS operators" do
    reflected = Ids::Parser.parse("⿾正")
    ternary = Ids::Parser.parse("⿲彳圭亍")

    assert_equal ["正"], Ids::Parser.leaves(reflected)
    assert_equal %w[彳 圭 亍], Ids::Parser.leaves(ternary)
  end

  test "normalises U plus notation before parsing" do
    assert_equal "⿰氵青", Ids::Parser.normalize("⿰ U+6C35 U+9752")
  end

  test "treats IDS entities as one component" do
    tree = Ids::Parser.parse("⿰&CDP-8BF5;青")

    assert_equal ["&CDP-8BF5;", "青"], Ids::Parser.leaves(tree)
  end

  test "parses yi-bai special components and operator qualifiers" do
    samples = {
      "#(H)" => ["#(H)"],
      "⿻[1:]亅⿱⿻𠃊一八" => ["亅", "𠃊", "一", "八"],
      "⿱丶#(㇇乀)" => ["丶", "#(㇇乀)"],
      "⿱丿⿹#(-𠃌㇉)一" => ["丿", "#(-𠃌㇉)", "一"]
    }

    samples.each do |expression, leaves|
      tree = Ids::Parser.parse(expression)
      assert_equal leaves, Ids::Parser.leaves(tree), expression
    end

    assert_equal "⿻亅⿱⿻𠃊一八", Ids::Parser.normalize("⿻[1:]亅⿱⿻𠃊一八")
  end

  test "rejects incomplete IDS" do
    assert_raises(Ids::Parser::ParseError) { Ids::Parser.parse("⿰氵") }
  end
end
