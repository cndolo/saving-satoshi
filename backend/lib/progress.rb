# frozen_string_literal: true
module CourseBackend
  module Progress
    module_function

    def valid_lessons?(lessons)
      lessons.is_a?(Array) && lessons.size <= 1000 && lessons.all? do |lesson|
        lesson.is_a?(Hash) && lesson['id'].is_a?(String) && lesson['id'].size.between?(1, 100) &&
          lesson['path'].is_a?(String) && lesson['path'].size <= 500 &&
          [true, false].include?(lesson['completed'])
      end
    end

    def valid?(progress)
      return false unless progress.is_a?(Hash) && progress['currentChapter'].is_a?(Integer) &&
                          progress['currentChapter'].positive? && progress['currentLesson'].is_a?(String) &&
                          progress['currentLesson'].size.between?(1, 100)
      chapters = progress['chapters']
      return false unless chapters.is_a?(Array) && chapters.size.between?(1, 100)
      chapters.all? do |chapter|
        next false unless chapter.is_a?(Hash) && chapter['id'].is_a?(Integer) && chapter['id'].positive? &&
                          [true, false].include?(chapter['completed'])
        if chapter['hasDifficulty'] == false
          valid_lessons?(chapter['lessons'])
        elsif chapter['hasDifficulty'] == true
          difficulties = chapter['difficulties']
          difficulties.is_a?(Array) && difficulties.size.between?(1, 10) &&
            difficulties.any? { |d| d.is_a?(Hash) && d['level'] == chapter['selectedDifficulty'] } &&
            difficulties.all? do |difficulty|
              difficulty.is_a?(Hash) && difficulty['level'].is_a?(String) &&
                [true, false].include?(difficulty['completed']) && valid_lessons?(difficulty['lessons'])
            end
        else
          false
        end
      end
    end

    # Count only visible course chapters and the selected difficulty track.
    # Defaults also contain chapters 4–7, which this course deliberately omits.
    def metrics(progress, chapter_ids)
      lessons = progress.fetch('chapters', []).select { |c| chapter_ids.include?(c['id']) }.flat_map do |chapter|
        if chapter['hasDifficulty']
          track = chapter.fetch('difficulties', []).find { |d| d['level'] == chapter['selectedDifficulty'] }
          track ? track.fetch('lessons', []) : []
        else
          chapter.fetch('lessons', [])
        end
      end
      lessons = lessons.uniq { |lesson| lesson['id'] }
      complete = lessons.count { |lesson| lesson['completed'] == true }
      [complete, lessons.size, lessons.empty? ? 0 : (100.0 * complete / lessons.size).round(1)]
    end
  end
end
