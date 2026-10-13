# frozen_string_literal: true
require 'sqlite3'
require 'fileutils'
require 'time'

module CourseBackend
  class Store
    DEFAULT_PATH = File.expand_path('../var/course.sqlite3', __dir__)
    attr_reader :db

    def self.path
      File.expand_path(ENV.fetch('DATABASE_PATH', DEFAULT_PATH))
    end

    def self.prepare(path = self.path)
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      # Restrict database, WAL and SHM permissions at creation.
      File.open(path, File::RDWR | File::CREAT, 0o600).close
      File.chmod(0o600, path)
      store = new(path)
      store.db.execute('PRAGMA journal_mode = WAL')
      store.db.execute_batch(<<~SQL)
        CREATE TABLE IF NOT EXISTS users (
          id INTEGER PRIMARY KEY,
          username TEXT NOT NULL UNIQUE COLLATE NOCASE,
          password_hash TEXT NOT NULL,
          key_lookup TEXT,
          avatar TEXT NOT NULL DEFAULT '/assets/avatars/1.png',
          created_at TEXT NOT NULL,
          last_login TEXT,
          active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1))
        );
        CREATE TABLE IF NOT EXISTS sessions (
          token_hash TEXT PRIMARY KEY,
          user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          created_at TEXT NOT NULL,
          expires_at INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS sessions_user ON sessions(user_id);
        CREATE TABLE IF NOT EXISTS progress (
          user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
          progress_json TEXT,
          lesson_data_json TEXT NOT NULL DEFAULT '{}',
          updated_at TEXT
        );
      SQL
      # Small additive migration for databases created by the first backend version.
      columns = store.db.table_info('users').map { |column| column['name'] }
      store.db.execute('ALTER TABLE users ADD COLUMN key_lookup TEXT') unless columns.include?('key_lookup')
      unless columns.include?('avatar')
        store.db.execute("ALTER TABLE users ADD COLUMN avatar TEXT NOT NULL DEFAULT '/assets/avatars/1.png'")
      end
      store.db.execute('CREATE UNIQUE INDEX IF NOT EXISTS users_key_lookup ON users(key_lookup)')
    ensure
      store&.close
    end

    def initialize(path = self.class.path)
      @db = SQLite3::Database.new(path)
      @db.results_as_hash = true
      @db.busy_timeout = 5000
      @db.execute('PRAGMA foreign_keys = ON')
    end

    def close
      @db.close unless @db.closed?
    end

    def self.now
      Time.now.utc.iso8601(6)
    end

    def user(username)
      @db.get_first_row('SELECT * FROM users WHERE username = ?', [username])
    end

    def user_by_key(key_lookup)
      @db.get_first_row('SELECT * FROM users WHERE key_lookup = ?', [key_lookup])
    end

    def create_user(username, password_hash, key_lookup: nil, avatar: '/assets/avatars/1.png')
      @db.execute('INSERT INTO users(username, password_hash, key_lookup, avatar, created_at) VALUES (?, ?, ?, ?, ?)',
                  [username, password_hash, key_lookup, avatar, self.class.now])
      @db.execute('INSERT INTO progress(user_id) VALUES (?)', [@db.last_insert_row_id])
    end

    # Roll back exceptions and Sinatra halt/throw alike.
    def transaction
      @db.execute('BEGIN IMMEDIATE')
      committed = false
      begin
        result = yield
        @db.commit
        committed = true
        result
      ensure
        @db.rollback unless committed
      end
    end

    # SQLite's online backup API includes committed WAL changes in one snapshot.
    def backup(destination)
      raise ArgumentError, 'Backup destination already exists' if File.exist?(destination)
      raise ArgumentError, 'Backup must use a different path' if File.expand_path(destination) == self.class.path
      File.open(destination, File::WRONLY | File::CREAT | File::EXCL, 0o600).close
      created = true
      target = SQLite3::Database.new(destination)
      backup = SQLite3::Backup.new(target, 'main', @db, 'main')
      result = backup.step(-1)
      raise 'Database busy; retry backup' unless result == SQLite3::Constants::ErrorCode::DONE
      successful = true
    ensure
      backup&.finish
      target&.close
      File.unlink(destination) if created && !successful
    end
  end
end
