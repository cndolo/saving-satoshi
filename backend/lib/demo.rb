# frozen_string_literal: true
require_relative 'admin'

module CourseBackend
  module Demo
    FIXTURE_DIRECTORY = File.expand_path('../demo', __dir__)
    DEFAULT_PATH = File.expand_path('../var/demo.sqlite3', __dir__)
    module_function

    # Public, synthetic demo data only. Never use these accounts for a real course.
    # DATABASE_PATH is intentionally ignored: the default course database stays untouched.
    def create(path = DEFAULT_PATH)
      path = File.expand_path(path)
      csv_path = File.join(FIXTURE_DIRECTORY, 'accounts.csv')
      scenarios = JSON.parse(File.read(File.join(FIXTURE_DIRECTORY, 'scenarios.json')))
      usernames = CSV.read(csv_path, headers: true).map { |row| row['username'] }
      raise ArgumentError, 'Demo scenarios must match the CSV accounts' unless scenarios.keys.sort == usernames.sort
      scenarios.each_value do |scenario|
        raise ArgumentError, 'Invalid demo account status' unless [true, false].include?(scenario['active'])
        progress = scenario['progress_state']
        raise ArgumentError, 'Invalid demo progress' unless progress.nil? || Progress.valid?(progress)
      end

      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      # Exclusive creation also refuses existing databases and symlinks.
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600).close
      created = true
      Store.prepare(path)
      store = Store.new(path)
      Admin.new(store).import(csv_path)
      store.transaction do
        scenarios.each do |username, scenario|
          user = store.user(username)
          store.db.execute('UPDATE users SET active = ?, created_at = ?, last_login = ? WHERE id = ?',
                           [scenario['active'] ? 1 : 0, scenario['created_at'], scenario['last_login'], user['id']])
          progress = scenario['progress_state']
          store.db.execute('UPDATE progress SET progress_json = ?, updated_at = ? WHERE user_id = ?',
                           [progress && JSON.generate(progress), scenario['progress_updated_at'], user['id']])
        end
      end
      successful = true
      path
    ensure
      store&.close
      # Remove only files created by this attempt if generation failed.
      if created && !successful
        [path, "#{path}-wal", "#{path}-shm"].each { |file| File.unlink(file) if File.exist?(file) }
      end
    end
  end
end
