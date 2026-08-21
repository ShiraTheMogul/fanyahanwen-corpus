require_relative "../test_helper"

class CorpusEntryOrderingTest < ActiveSupport::TestCase
  test "uses chronological period order for the current Chinese region folders" do
    names = %w[
      三國 中華人民共和國 中華帝國 中華民國 五代十國 元朝 南北朝
      周朝 唐朝 商殷朝 宋朝 明朝 晉朝 清朝 漢朝 秦朝 隋朝
    ]

    ordering = CorpusEntryOrdering.new
    ordering.prepare(names)

    assert_equal "period", ordering.effective_mode
    assert_equal(
      %w[
        商殷朝 周朝 秦朝 漢朝 三國 晉朝 南北朝 隋朝 唐朝 五代十國
        宋朝 元朝 明朝 清朝 中華民國 中華帝國 中華人民共和國
      ],
      names.sort_by { |name| ordering.key(name) }
    )
  end


  test "orders current Japanese historical periods chronologically" do
    names = %w[
      令和時代 大正時代 奈良時代 安土桃山時代 室町時代 平安時代
      平成時代 明治時代 昭和時代 江戸時代 鎌倉時代 弥生時代 古墳時代 飛鳥時代
    ]
    ordering = CorpusEntryOrdering.new
    ordering.prepare(names)

    assert_equal(
      %w[
        弥生時代 古墳時代 飛鳥時代 奈良時代 平安時代 鎌倉時代 室町時代
        安土桃山時代 江戸時代 明治時代 大正時代 昭和時代 平成時代 令和時代
      ],
      names.sort_by { |name| ordering.key(name) }
    )
  end

  test "orders current Vietnamese dynasties chronologically" do
    names = %w[後黎朝 李朝 莫朝 西山朝 阮朝 陳朝]
    ordering = CorpusEntryOrdering.new
    ordering.prepare(names)

    assert_equal(
      %w[李朝 陳朝 後黎朝 莫朝 西山朝 阮朝],
      names.sort_by { |name| ordering.key(name) }
    )
  end

  test "orders current Korean period folders and leaves undated material last" do
    names = %w[三國 古朝鮮 大韓國 朝鮮王朝 渤海 無年份 耽羅 高麗]
    ordering = CorpusEntryOrdering.new(context_path: "朝鮮漢文/clean")
    ordering.prepare(names)

    assert_equal(
      %w[古朝鮮 三國 耽羅 渤海 高麗 朝鮮王朝 大韓國 無年份],
      names.sort_by { |name| ordering.key(name) }
    )
  end

  test "YES order snapshot is loaded with first occurrence winning duplicates" do
    rank = CorpusEntryOrdering.yes_order_rank

    assert_equal 21_522, rank.length
    assert_equal 0, rank.fetch("一")
    assert_equal 1, rank.fetch("二")
    assert_equal 2, rank.fetch("三")
    assert_equal 6_012, rank.fetch("兀")
  end

  test "YES order follows the published character sequence and puts unranked text after it" do
    names = ["A.txt", "日.txt", "木.txt", "土.txt", "三.txt", "二.txt", "一.txt"]
    ordering = CorpusEntryOrdering.new(requested_mode: "yes")
    ordering.prepare(names)

    assert_equal "yes", ordering.effective_mode
    assert ordering.yes_available?
    assert_equal(
      ["一.txt", "二.txt", "三.txt", "土.txt", "木.txt", "日.txt", "A.txt"],
      names.sort_by { |name| ordering.key(name) }
    )
  end

  test "thousand character classic overlay can sit on top of YES order" do
    names = ["一.txt", "地.txt", "天.txt"]
    ordering = CorpusEntryOrdering.new(requested_mode: "yes", qianziwen_first: "1")
    ordering.prepare(names)

    assert_equal ["天.txt", "地.txt", "一.txt"], names.sort_by { |name| ordering.key(name) }
  end

  test "thousand character classic overlay contains one thousand distinct characters" do
    rank = CorpusEntryOrdering.qianziwen_rank

    assert_equal 1_000, rank.length
    assert_equal 0, rank.fetch("天")
    assert_equal 1, rank.fetch("地")
  end

  test "thousand character classic overlay runs before the selected base order" do
    names = ["龘.txt", "地.txt", "天.txt"]
    ordering = CorpusEntryOrdering.new(requested_mode: "pc", qianziwen_first: "1")
    ordering.prepare(names)

    assert_equal ["天.txt", "地.txt", "龘.txt"], names.sort_by { |name| ordering.key(name) }
  end

  test "orders nested Zhou periods from broad eras into their historical sequence" do
    zhou = %w[東周 西周]
    ordering = CorpusEntryOrdering.new(context_path: "中國漢文/clean/周朝")
    ordering.prepare(zhou)

    assert_equal "period", ordering.effective_mode
    assert_equal %w[西周 東周], zhou.sort_by { |name| ordering.key(name) }

    eastern_zhou = %w[戰國時代 春秋時代]
    ordering = CorpusEntryOrdering.new(context_path: "中國漢文/clean/周朝/東周")
    ordering.prepare(eastern_zhou)

    assert_equal %w[春秋時代 戰國時代], eastern_zhou.sort_by { |name| ordering.key(name) }
  end

  test "orders the Chinese Three Kingdoms within the Chinese corpus context" do
    names = %w[東吳 蜀漢 曹魏]
    ordering = CorpusEntryOrdering.new(context_path: "中國漢文/clean/三國")
    ordering.prepare(names)

    assert_equal "period", ordering.effective_mode
    assert_equal %w[曹魏 蜀漢 東吳], names.sort_by { |name| ordering.key(name) }
  end

  test "orders the Korean Three Kingdoms using Korean chronology" do
    names = %w[百濟 高句麗 新羅]
    ordering = CorpusEntryOrdering.new(context_path: "朝鮮漢文/clean/三國")
    ordering.prepare(names)

    assert_equal "period", ordering.effective_mode
    assert_equal %w[新羅 高句麗 百濟], names.sort_by { |name| ordering.key(name) }
  end

  test "orders nested Five Dynasties and Song-period states chronologically" do
    five_dynasties = %w[後周 後唐 後晉 後梁 後漢]
    ordering = CorpusEntryOrdering.new(context_path: "中國漢文/clean/五代十國/五代")
    ordering.prepare(five_dynasties)

    assert_equal %w[後梁 後唐 後晉 後漢 後周], five_dynasties.sort_by { |name| ordering.key(name) }

    song_states = %w[北宋 南宋 西夏 遼朝 金朝]
    ordering = CorpusEntryOrdering.new(context_path: "中國漢文/clean/宋朝")
    ordering.prepare(song_states)

    assert_equal %w[遼朝 北宋 西夏 金朝 南宋], song_states.sort_by { |name| ordering.key(name) }
  end

  test "Cangjie plus Thousand Character Classic is safe with mixed Han and non-Han names" do
    names = ["龘.txt", "archive"]
    ordering = CorpusEntryOrdering.new(requested_mode: "cangjie", qianziwen_first: "1")
    ordering.prepare(names)

    # Force a known string-valued Cangjie key so this exercises the exact
    # String-versus-Integer comparison that previously crashed Array#sort_by.
    ordering.instance_variable_get(:@values)["龘".ord] = "ABCD"

    assert_nothing_raised do
      assert_equal ["龘.txt", "archive"], names.sort_by { |name| ordering.key(name) }
    end
  end

end
