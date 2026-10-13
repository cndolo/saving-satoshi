'use client'

import { useEffect, useState } from 'react'
import { useAtom } from 'jotai'
import { getData } from 'api/data'
import { detectLanguage, Language } from 'lib/SavedCode'
import { accountAtom, currentLanguageAtom } from 'state/state'

export default function usePrevLessonLanguage(prevLessonId: string) {
  const [prevData, setPrevData] = useState<any>({ lesson_id: '', data: '' })
  const [isLoading, setIsLoading] = useState(true)
  const [detectedLang, setDetectedLang] = useState<Language>(
    Language.JavaScript
  )
  const [account] = useAtom(accountAtom)
  const [language, setCurrentLanguage] = useAtom(currentLanguageAtom)

  useEffect(() => {
    let cancelled = false
    setPrevData({ lesson_id: '', data: '' })
    setIsLoading(true)
    const fetchPrevLesson = async () => {
      const data = account ? await getData(prevLessonId) : undefined
      if (cancelled) return
      if (data?.code) {
        const decodedData = data.code.getDecoded()
        setPrevData({
          lesson_id: prevLessonId,
          data: decodedData,
        })

        const detected = detectLanguage(decodedData)
        setDetectedLang(detected)

        if (detected !== Language.Unknown) {
          setCurrentLanguage(detected)
        }
      } else {
        setDetectedLang(language)
      }
      setIsLoading(false)
    }

    fetchPrevLesson()
    return () => {
      cancelled = true
    }
  }, [prevLessonId, setCurrentLanguage, language, account?.id])

  return { prevData, isLoading, detectedLanguage: detectedLang }
}
