# frozen_string_literal: true

require_relative "../test_helper"

class IdsSourceRowParserTest < ActiveSupport::TestCase
  test "splits upstream primary and alternative IDS lists and preserves indicators" do
    row = Ids::SourceRowParser.new.parse("他\t⿰亻也(G,T);⿰人也(H)\t⿰亻也\n")

    assert_equal "他", row.glyph
    assert_equal ["⿰亻也", "⿰人也", "⿰亻也"], row.candidates.map(&:expression)
    assert_equal %w[G T], row.candidates.first.indicators
    assert_equal ["primary", "primary", "alternative"], row.candidates.map(&:list_type)
  end

  test "does not split the semicolon that terminates an IDS entity" do
    row = Ids::SourceRowParser.new.parse("清\t⿰&CDP-8BF5;青(G);⿱日月(T)\t\n")

    assert_equal ["⿰&CDP-8BF5;青", "⿱日月"], row.candidates.map(&:expression)
    assert row.candidates.all? { |candidate| Ids::Parser.valid?(candidate.expression) }
  end

  test "parses real yi-bai level 1 alternatives and variant indicators" do
    row = Ids::SourceRowParser.new.parse("北\t⿲二丨匕(.,T);⿰⿱⿰一丨一匕(H);⿲二丨匕(th,wh)\n")

    assert_equal ["⿲二丨匕", "⿰⿱⿰一丨一匕", "⿲二丨匕"], row.candidates.map(&:expression)
    assert_equal [".", "T"], row.candidates.first.indicators
    assert row.candidates.all? { |candidate| Ids::Parser.valid?(candidate.expression) }
  end

  test "accepts Unicode 17 extension characters that older Ruby Han properties miss" do
    {
      "𫜺" => "⿱山田",
      "𬺢" => "⿱一八",
      "𳎰" => "⿰日月"
    }.each do |glyph, expression|
      row = Ids::SourceRowParser.new.parse("#{glyph}\t#{expression}\n")
      assert_equal glyph, row.glyph
      assert_equal [expression], row.candidates.map(&:expression)
    end
  end

  test "accepts and splits the structural rows that previously failed level 1 diagnostics" do
    lines = [
      "◜\t#(Qd)\n",
      "◝\t#(Qa)\n",
      "◞\t#(Qb)\n",
      "◟\t#(Qc)\n",
      "⺀\t⿱丶丶\n",
      "⺄\t#(HNg)\n",
      "⺆\t#(-丿𠃌)(.);#(-丿𠃍)(z)\n",
      "⺈\t⿰丿乛\n",
      "⺊\t⿰丨一\n",
      "⺌\t⿰丶リ  ⿻丨丷\n",
      "⺕\t⿻コ一\n",
      "⺝\t⿵冂二  ⿵𠔼一\n",
      "⺼\t⿵⺆冫(.);⿵⺆⺀(d)\n",
      "〢\t⿰丨丨\n",
      "〣\t⿰丨〢  ⿰〢丨;⿴〢丨\n",
      "コ\t#(一-𠃍)\n",
      "ス\t⿸㇇丶(.);⿸㇇乀(n)\n",
      "ユ\t⿱𠃍一\n",
      "リ\t⿰丨丿\n",
      "㇀\t#(T)\n"
    ]

    rows = lines.map { |line| Ids::SourceRowParser.new.parse(line) }

    assert_equal 27, rows.sum { |row| row.candidates.length }
    rows.each do |row|
      assert CharacterData::IndexableCharacter.single?(row.glyph)
      row.candidates.each { |candidate| assert Ids::Parser.valid?(candidate.expression) }
    end

    assert_equal ["⿰丶リ", "⿻丨丷"], rows[9].candidates.map(&:expression)
    assert_equal ["⿰丨〢", "⿰〢丨", "⿴〢丨"], rows[14].candidates.map(&:expression)
  end

  test "accepts kana and Hangul as ordinary source subjects" do
    { "の" => "#(kana)", "한" => "#(hangul)" }.each do |glyph, expression|
      row = Ids::SourceRowParser.new.parse("#{glyph}\t#{expression}\n")
      assert_equal glyph, row.glyph
      assert_equal [expression], row.candidates.map(&:expression)
    end
  end

  test "preserves yi-bai annotations while parsing special components" do
    row = Ids::SourceRowParser.new.parse("一\t#(H)(.);{一}#(T)(t)\n")

    assert_equal ["#(H)", "#(T)"], row.candidates.map(&:expression)
    assert_equal [["."], ["t"]], row.candidates.map(&:indicators)
    assert_equal [[], ["一"]], row.candidates.map(&:annotations)
    assert row.candidates.all? { |candidate| Ids::Parser.valid?(candidate.expression) }
  end

  test "keeps yi-bai lv2 inline and trailing annotations out of functional IDS" do
    examples = {
      "⿶𲻋与qs(H,T)" => ["⿶𲻋与", %w[H T]],
      "⿱⿴𦥑与qs𬺢(g.n,gpn)" => ["⿱⿴𦥑与𬺢", ["g.n", "gpn"]],
      "⿳⿴𦥑与qs冖玉(T)" => ["⿳⿴𦥑与冖玉", ["T"]],
      "⿱⿴𦥑与qs又" => ["⿱⿴𦥑与又", []],
      "⿱⿴𦥑与qs肎(T)" => ["⿱⿴𦥑与肎", ["T"]],
      "⿱⿴𦥑与qs𦘫(T)" => ["⿱⿴𦥑与𦘫", ["T"]],
      "⿱⿴𦥑与qs廾(T)" => ["⿱⿴𦥑与廾", ["T"]],
      "⿱⿴𦥑与qs𲻋(T)" => ["⿱⿴𦥑与𲻋", ["T"]],
      "⿱⿲〢与qs⿹𠃍二𬺢(T)" => ["⿱⿲〢与⿹𠃍二𬺢", ["T"]],
      "⿳⿴𦥑与qs一⿰彡⿱⿺人丶⿻丄𬺣" => ["⿳⿴𦥑与一⿰彡⿱⿺人丶⿻丄𬺣", []]
    }

    examples.each do |raw, (functional, indicators)|
      row = Ids::SourceRowParser.new.parse("明\t#{raw}\n")
      candidate = row.candidates.fetch(0)

      assert_equal functional, candidate.expression, raw
      assert_equal ["qs"], candidate.annotations, raw
      assert_equal indicators, candidate.indicators, raw
      assert_equal raw, candidate.raw_expression, raw
      assert Ids::Parser.valid?(candidate.expression), raw
    end
  end

  test "strips yi-bai lv0 operand modifiers and IDC qualifiers from functional IDS" do
    examples = {
      "⿱一.亅" => "⿱一亅",
      "⿱一.㇉" => "⿱一㇉",
      "⿻乚.一.(.)" => "⿻乚一",
      "⿻乚w一.(T)" => "⿻乚一",
      "⿻乚t一.(t)" => "⿻乚一",
      "⿱丨一.(.)" => "⿱丨一",
      "⿱丨一t(t)" => "⿱丨一",
      "⿱一.丨" => "⿱一丨",
      "⿱一.丿" => "⿱一丿",
      "⿱一.勹" => "⿱一勹",
      "⿻𠂇.乀.(.)" => "⿻𠂇乀",
      "⿻𠂇.乀t(K)" => "⿻𠂇乀",
      "⿻𠂇.丶.(d)" => "⿻𠂇丶",
      "⿱一.二." => "⿱一二",
      "⿱二.一." => "⿱二一",
      "⿱⺊一.(.)" => "⿱⺊一",
      "⿱⺊一t(t)" => "⿱⺊一",
      "⿺丄.一.(.)" => "⿺丄一",
      "⿺丄t一.(t)" => "⿺丄一",
      "⿱一.卜." => "⿱一卜",
      "⿸丅丶." => "⿸丅丶",
      "⿸丆卜." => "⿸丆卜",
      "⿹⿺㇉一.一.(.)" => "⿹⿺㇉一一",
      "⿺⿻[b]㇉一.一.(J)" => "⿺⿻㇉一一",
      "⿹⿺㇉一.一t(.t)" => "⿹⿺㇉一一",
      "⿹⿺𠃑.一.丨(qs)" => "⿹⿺𠃑一丨",
      "⿱一.⿰⿺𠃊.丨𠃌" => "⿱一⿰⿺𠃊丨𠃌",
      "⿱一.⿺㇉⺊(.)" => "⿱一⿺㇉⺊",
      "⿼ユ.十.(.)" => "⿼ユ十",
      "⿻⿼ユ.丨一.(H)" => "⿻⿼ユ丨一",
      "⿻⿼コ丨一.(y)" => "⿻⿼コ丨一",
      "⿼ユt十.(.t)" => "⿼ユ十",
      "⿻⿼ユt丨一.(xt)" => "⿻⿼ユ丨一",
      "⿱刃J一." => "⿱刃一",
      "⿱⿻𠃑.二.丶." => "⿱⿻𠃑二丶",
      "⿴𠀃.二.(.)" => "⿴𠀃二",
      "⿴𠀃t二.(t)" => "⿴𠀃二",
      "⿱不一.(.)" => "⿱不一",
      "⿱不一t(t)" => "⿱不一",
      "⿻⿺𠃊.凵y一.(.)" => "⿻⿺𠃊凵一",
      "⿻⿺𠃊t凵y一.(t)" => "⿻⿺𠃊凵一",
      "⿻山一.(.)" => "⿻山一",
      "{?0丗}⿻⿺𠃊.〢一.(P)" => "⿻⿺𠃊〢一",
      "{丗}⿱卅s一.(T)" => "⿱卅一",
      "⿱⿸𠂆s丅一.(.)" => "⿱⿸𠂆丅一",
      "⿱⿸𠂆s丅一t(t)" => "⿱⿸𠂆丅一",
      "⿱一.内.(.)" => "⿱一内",
      "⿱一.内P(.n)" => "⿱一内",
      "⿱一.内z.(z.)" => "⿱一内",
      "⿻𠆣d冂.(.)" => "⿻𠆣冂"
    }

    parser = Ids::SourceRowParser.new
    examples.each do |raw, functional|
      candidate = parser.parse("明\t#{raw}\n").candidates.fetch(0)

      assert_equal functional, candidate.expression, raw
      assert_equal raw, candidate.raw_expression, raw
      assert Ids::Parser.valid?(candidate.expression), raw
    end

    qualified = parser.parse("明\t⿺⿻[b]㇉一.一.(J)\n").candidates.fetch(0)
    assert_includes qualified.annotations, "[b]"
    assert_includes qualified.annotations, "."
    assert_equal ["J"], qualified.indicators
  end

  test "rejects IDS operators as source subjects" do
    error = assert_raises(Ids::SourceRowParser::ParseError) do
      Ids::SourceRowParser.new.parse("⿰\t⿰日月\n")
    end

    assert_match(/not one indexable character/, error.message)
  end
end
