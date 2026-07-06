# frozen_string_literal: true

class ApplicationMailer < ActionMailer::Base
  default from: "Fanya Hanwen Corpus <webmaster@fanyahanwen-corpus.cn>",
          reply_to: "webmaster@fanyahanwen-corpus.cn"
  layout "mailer"
end
