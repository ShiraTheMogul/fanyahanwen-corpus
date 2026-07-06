# frozen_string_literal: true

class CorpusSearchMailer < ApplicationMailer
  def full_search_complete(email:, prepared_search:, download_url:, expires_at: nil)
    @prepared_search = prepared_search
    @download_url = download_url
    @expires_at = expires_at
    mail(to: email, subject: I18n.t("corpus_search.mailer.complete.subject"))
  end
end
