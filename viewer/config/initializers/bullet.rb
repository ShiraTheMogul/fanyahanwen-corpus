if Rails.env.development?
  Rails.application.config.after_initialize do
    if defined?(Bullet)
      Bullet.enable = true
      Bullet.alert = false
      Bullet.bullet_logger = true
      Bullet.rails_logger = true
      Bullet.add_footer = true
    end
  end
end
