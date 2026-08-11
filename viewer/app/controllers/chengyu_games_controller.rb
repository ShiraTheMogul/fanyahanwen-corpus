# frozen_string_literal: true

class ChengyuGamesController < ApplicationController
  protect_from_forgery with: :exception

  def jielong
    @chengyu_ready = ChengyuForm.table_exists? && ChengyuForm.exists?
    @standard_count = @chengyu_ready ? ChengyuForm.standard_game_pool.distinct.count(:chengyu_id) : 0
    @hard_count = @chengyu_ready ? ChengyuForm.hard_game_pool.distinct.count(:chengyu_id) : 0
  rescue ActiveRecord::StatementInvalid
    @chengyu_ready = false
    @standard_count = 0
    @hard_count = 0
  end

  def start
    render_game_result(game.start)
  rescue ActiveRecord::StatementInvalid => e
    render json: { ok: false, error: "Chengyu data is not ready. Run the Chengyu migration and importer first.", detail: e.message }, status: :service_unavailable
  end

  def turn
    result = game.submit(answer: params[:answer], current_form_id: params[:current_form_id])
    render_game_result(result)
  rescue ActiveRecord::StatementInvalid => e
    render json: { ok: false, error: "Chengyu data is not ready. Run the Chengyu migration and importer first.", detail: e.message }, status: :service_unavailable
  end

  def alternatives
    result = game.alternatives(current_form_id: params[:current_form_id], limit: 5)
    render_game_result(result)
  rescue ActiveRecord::StatementInvalid => e
    render json: { ok: false, error: "Chengyu data is not ready. Run the Chengyu migration and importer first.", detail: e.message }, status: :service_unavailable
  end

  private

  def game
    ChengyuGames::Jielong.new(
      mode: params[:mode],
      opponent: params[:opponent],
      used_family_ids: normalized_used_family_ids,
      score: params[:score]
    )
  end

  def normalized_used_family_ids
    Array(params[:used_family_ids]).filter_map do |value|
      integer = Integer(value, exception: false)
      integer if integer&.positive?
    end.uniq.first(5_000)
  end

  def render_game_result(result)
    status = result[:ok] ? :ok : :unprocessable_entity
    render json: result, status: status
  end
end
