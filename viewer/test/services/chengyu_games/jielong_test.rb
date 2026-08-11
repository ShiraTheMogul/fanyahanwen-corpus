# frozen_string_literal: true

require "test_helper"

class ChengyuGamesJielongTest < ActiveSupport::TestCase
  test "free typed answer chains by exact written Han character and computer replies" do
    current = make_form("一心一意", "G1")
    player = make_form("意氣風發", "G2")
    computer = make_form("發憤圖強", "G3")
    make_form("強詞奪理", "G4")

    game = ChengyuGames::Jielong.new(
      mode: "standard",
      opponent: "adaptive",
      used_family_ids: [current.chengyu_id],
      score: 0,
      random: Random.new(1)
    )

    result = game.submit(answer: player.form_text, current_form_id: current.id)

    assert result[:ok]
    assert_equal player.form_text, result.dig(:user, :text)
    assert_includes result.dig(:user, :corpus_search_url), "q="
    assert_equal computer.form_text, result.dig(:computer, :text)
    assert_equal computer.id, result[:current_form_id]
    refute result[:round_over]
  end

  test "standard mode rejects a family already used even through another form" do
    current = make_form("一心一意", "R1")
    player = make_form("意氣風發", "R2")

    game = ChengyuGames::Jielong.new(
      mode: "standard",
      opponent: "adaptive",
      used_family_ids: [current.chengyu_id, player.chengyu_id]
    )

    result = game.submit(answer: player.form_text, current_form_id: current.id)
    refute result[:ok]
    assert_equal "repeat", result[:code]
  end

  test "zen permits repeats and hard accepts longer compound forms" do
    current = make_form("一心一意", "Z1")
    zen_player = make_form("意氣風發", "Z2")
    make_form("發憤圖強", "Z3")

    zen = ChengyuGames::Jielong.new(mode: "zen", opponent: "adaptive", used_family_ids: [current.chengyu_id, zen_player.chengyu_id])
    assert zen.submit(answer: zen_player.form_text, current_form_id: current.id)[:ok]

    hard_current = make_form("萬眾一心", "H1")
    compound = make_form("心有餘，力不足", "H2", script_class: "han_with_punctuation", strict: false)
    make_form("足智多謀", "H3")

    hard = ChengyuGames::Jielong.new(mode: "hard", opponent: "adaptive", used_family_ids: [hard_current.chengyu_id])
    result = hard.submit(answer: "心有餘力不足", current_form_id: hard_current.id)
    assert result[:ok]
    assert_equal compound.id, result.dig(:user, :form_id)
  end

  test "wrong initial character is rejected without suggesting an answer" do
    current = make_form("一心一意", "W1")
    make_form("風和日麗", "W2")

    result = ChengyuGames::Jielong.new(mode: "standard", opponent: "adaptive", used_family_ids: [current.chengyu_id])
      .submit(answer: "風和日麗", current_form_id: current.id)

    refute result[:ok]
    assert_equal "wrong_chain", result[:code]
    assert_match(/must begin with 意/, result[:error])
  end

  private

  def make_form(text, source_id, script_class: "han", strict: true)
    han = text.each_char.select { |char| char.match?(/\A\p{Han}\z/u) }
    first = character(han.first)
    last = character(han.last)
    family = Chengyu.create!(source_family_id: "#{source_id}-F", display_form: text)
    ChengyuForm.create!(
      chengyu: family,
      source_form_id: "#{source_id}-FORM",
      form_text: text,
      game_key: han.join,
      is_display_form: true,
      script_class: script_class,
      codepoint_length: text.codepoints.length,
      han_character_count: han.length,
      is_strict_han: strict,
      contains_punctuation: text.each_char.any? { |char| char.match?(/\A\p{P}\z/u) },
      first_character_codepoint: first,
      last_character_codepoint: last
    )
  end

  def character(glyph)
    CharacterCodepoint.find_or_create_by!(codepoint: glyph.ord) { |row| row.chr = glyph }
  end
end
