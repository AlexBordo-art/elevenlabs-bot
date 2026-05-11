CREATE DATABASE IF NOT EXISTS elevenlabs_telegram_bot
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE elevenlabs_telegram_bot;

CREATE TABLE users (
  id               INT AUTO_INCREMENT PRIMARY KEY,
  telegram_user_id BIGINT NOT NULL,
  username         VARCHAR(255) DEFAULT NULL,
  first_name       VARCHAR(255) DEFAULT NULL,
  last_name        VARCHAR(255) DEFAULT NULL,
  is_active        TINYINT(1) NOT NULL DEFAULT 1,
  created_at       TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at       TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY uniq_telegram_user_id (telegram_user_id)
) ENGINE=InnoDB;

CREATE TABLE user_agents (
  id                  INT AUTO_INCREMENT PRIMARY KEY,
  user_id             INT NOT NULL,
  elevenlabs_agent_id VARCHAR(255) NOT NULL,
  agent_name          VARCHAR(255) DEFAULT NULL,
  is_active           TINYINT(1) NOT NULL DEFAULT 1,
  created_at          TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at          TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  CONSTRAINT fk_user_agents_user
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
  UNIQUE KEY uniq_user_agent (user_id, elevenlabs_agent_id),
  KEY idx_user_id (user_id),
  KEY idx_agent_id (elevenlabs_agent_id)
) ENGINE=InnoDB;

CREATE TABLE user_sessions (
  telegram_user_id     BIGINT NOT NULL PRIMARY KEY,
  selected_agent_db_id INT DEFAULT NULL,
  current_action       ENUM(
                         'idle',
                         'awaiting_prompt',
                         'awaiting_welcome',
                         'awaiting_kb_text',
                         'awaiting_agent_name'
                       ) NOT NULL DEFAULT 'idle',
  context_data         JSON DEFAULT NULL,
  updated_at           TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  CONSTRAINT fk_sessions_agent
    FOREIGN KEY (selected_agent_db_id) REFERENCES user_agents(id) ON DELETE SET NULL,
  CONSTRAINT fk_sessions_user
    FOREIGN KEY (telegram_user_id) REFERENCES users(telegram_user_id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE action_logs (
  id               BIGINT AUTO_INCREMENT PRIMARY KEY,
  telegram_user_id BIGINT DEFAULT NULL,
  user_agent_id    INT DEFAULT NULL,
  action_type      VARCHAR(64) NOT NULL,
  status           ENUM('success','error','denied') NOT NULL,
  details          JSON DEFAULT NULL,
  error_message    TEXT DEFAULT NULL,
  created_at       TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY idx_logs_user    (telegram_user_id),
  KEY idx_logs_action  (action_type),
  KEY idx_logs_status  (status),
  KEY idx_logs_created (created_at)
) ENGINE=InnoDB;
