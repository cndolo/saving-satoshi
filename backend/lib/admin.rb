# frozen_string_literal: true
require 'csv'
require 'json'
require 'io/console'
require_relative 'store'
require_relative 'security'
require_relative 'progress'

module CourseBackend
  class Admin
    def initialize(store)
      @store = store
    end

    def create(username, password)
      name = Security.username(username)
      key = Security.login_key(password)
      hash = Security.password_hash(key)
      @store.transaction { @store.create_user(name, hash, key_lookup: Security.key_lookup(key)) }
    end

    def require_user(username)
      @store.user(Security.username(username)) || raise(ArgumentError, 'User not found')
    end

    def set_active(username, active)
      @store.transaction do
        user = require_user(username)
        @store.db.execute('UPDATE users SET active = ? WHERE id = ?', [active ? 1 : 0, user['id']])
        @store.db.execute('DELETE FROM sessions WHERE user_id = ?', [user['id']])
      end
    end

    def delete(username)
      @store.transaction do
        user = require_user(username)
        @store.db.execute('DELETE FROM users WHERE id = ?', [user['id']])
      end
    end

    def reset_password(username, password)
      key = Security.login_key(password)
      hash = Security.password_hash(key)
      @store.transaction do
        user = require_user(username)
        @store.db.execute('UPDATE users SET password_hash = ?, key_lookup = ? WHERE id = ?', [hash, Security.key_lookup(key), user['id']])
        @store.db.execute('DELETE FROM sessions WHERE user_id = ?', [user['id']])
      end
    end

    # Validate the whole file first, then insert in one transaction. No partial import or silent reset.
    def import(path)
      rows = CSV.read(path, headers: true, encoding: 'bom|utf-8')
      raise ArgumentError, 'CSV requires username,password headers' unless rows.headers&.sort == %w[password username]
      raise ArgumentError, 'CSV must contain 1–2000 users' unless rows.size.between?(1, 2000)
      names, keys = [], []
      prepared = rows.each_with_index.map do |row, index|
        begin
          name = Security.username(row['username'])
          key = Security.login_key(row['password'])
          lookup = Security.key_lookup(key)
          raise ArgumentError, 'Duplicate or existing username' if names.include?(name) || @store.user(name)
          raise ArgumentError, 'Duplicate or existing login key' if keys.include?(lookup) || @store.user_by_key(lookup)
          raise ArgumentError, 'Too many CSV fields' if row.fields.size != 2
          names << name
          keys << lookup
          [name, Security.password_hash(key), lookup]
        rescue ArgumentError => e
          raise ArgumentError, "CSV row #{index + 2}: #{e.message}"
        end
      end
      @store.transaction { prepared.each { |name, hash, lookup| @store.create_user(name, hash, key_lookup: lookup) } }
      prepared.size
    end

    def list(io)
      csv = CSV.new(io)
      csv << %w[username active created_at last_login]
      @store.db.execute('SELECT username, active, created_at, last_login FROM users ORDER BY username').each do |user|
        csv << user.values_at('username', 'active', 'created_at', 'last_login')
      end
    end

    def export(io, chapter_ids: ENV.fetch('COURSE_CHAPTER_IDS', '1,2,3,8,9,10').split(',').map { |id| Integer(id) })
      csv = CSV.new(io)
      csv << %w[username active current_chapter current_lesson completed_lessons total_lessons progress_percent progress_updated_at last_login]
      @store.db.execute(<<~SQL).each do |row|
        SELECT users.username, users.active, users.last_login, progress.progress_json, progress.updated_at
        FROM users LEFT JOIN progress ON progress.user_id = users.id ORDER BY users.username
      SQL
        progress = row['progress_json'] ? JSON.parse(row['progress_json']) : {}
        completed, total, percent = Progress.metrics(progress, chapter_ids)
        csv << [row['username'], row['active'], progress['currentChapter'], progress['currentLesson'],
                completed, total, percent, row['updated_at'], row['last_login']].map { |value| safe_cell(value) }
      end
    end

    private

    # Progress is supplied by the browser. Do not let spreadsheet programs evaluate formulas.
    def safe_cell(value)
      value.is_a?(String) && value.match?(/\A[=+\-@\t\r\n]/) ? "'#{value}" : value
    end
  end

  class CLI
    USAGE = <<~TEXT
      Usage: bundle exec ruby bin/admin COMMAND
        init
        create USERNAME [--password-stdin]
        list
        deactivate USERNAME
        activate USERNAME
        delete USERNAME
        reset-password USERNAME [--password-stdin]
        import-csv PATH
        export-progress [NEW_CSV_PATH]
        backup NEW_SQLITE_PATH
      Passwords are 64-character hexadecimal login keys, entered without echo; --password-stdin reads one line from stdin.
    TEXT

    def self.run(args, input: $stdin, output: $stdout, errors: $stderr)
      command = args.shift
      return output.puts(USAGE) if command.nil? || %w[help --help -h].include?(command)
      Store.prepare
      store = Store.new
      admin = Admin.new(store)
      case command
      when 'init'
        check_args(args, 0)
        output.puts 'Database initialized'
      when 'create', 'reset-password'
        check_args(args, 1, 2)
        name = args.first
        raise ArgumentError, 'Unknown option' if args.size == 2 && args[1] != '--password-stdin'
        password = read_password(input, errors, args[1] == '--password-stdin')
        command == 'create' ? admin.create(name, password) : admin.reset_password(name, password)
        output.puts 'User created / password updated'
      when 'list'
        check_args(args, 0)
        admin.list(output)
      when 'deactivate', 'activate', 'delete'
        check_args(args, 1)
        command == 'delete' ? admin.delete(args.first) : admin.set_active(args.first, command == 'activate')
        output.puts 'User updated'
      when 'import-csv'
        check_args(args, 1)
        output.puts "Imported #{admin.import(args.first)} users"
      when 'export-progress'
        check_args(args, 0, 1)
        if args.first
          File.open(args.first, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |io| admin.export(io) }
          output.puts 'Progress exported'
        else
          admin.export(output)
        end
      when 'backup'
        check_args(args, 1)
        store.backup(args.first)
        output.puts 'Backup created'
      else
        raise ArgumentError, 'Unknown command; use --help'
      end
      0
    rescue SQLite3::ConstraintException
      errors.puts 'Error: duplicate username/login key or invalid database constraint'
      1
    rescue ArgumentError, CSV::MalformedCSVError, SystemCallError
      # CSV parser and OS exception values may include input text. Keep them out of logs.
      errors.puts 'Error: invalid arguments, CSV, user or path; check --help and input format'
      1
    ensure
      store&.close
    end

    def self.check_args(args, min, max = min)
      raise ArgumentError, 'Wrong number of arguments' unless args.size.between?(min, max)
    end

    def self.read_password(input, errors, from_stdin)
      if from_stdin
        return input.gets&.chomp
      end
      raise ArgumentError, 'Use --password-stdin for noninteractive input' unless input.tty?
      errors.print 'Password: '
      password = input.noecho(&:gets)&.chomp
      errors.print "\nRepeat password: "
      confirmation = input.noecho(&:gets)&.chomp
      errors.puts
      raise ArgumentError, 'Passwords do not match' unless password == confirmation
      password
    end
  end
end
