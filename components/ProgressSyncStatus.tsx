'use client'
import { useAtom, useAtomValue, useSetAtom } from 'jotai'
import { useState } from 'react'
import {
  courseProgressAtom,
  isProgressLoadedAtom,
  progressErrorAtom,
} from 'state/progress/atoms'
import { loadProgressAtom } from 'state/progress/actions'
import { useAuthFunctions } from 'state/AuthFunctions'
import { setProgress } from 'api/progress'

export default function ProgressSyncStatus() {
  const [error, setError] = useAtom(progressErrorAtom)
  const loaded = useAtomValue(isProgressLoadedAtom)
  const progress = useAtomValue(courseProgressAtom)
  const load = useSetAtom(loadProgressAtom)
  const { check } = useAuthFunctions()
  const [retrying, setRetrying] = useState(false)
  if (!error) return null
  return (
    <div
      role="alert"
      className="bg-red-950 fixed bottom-4 left-4 right-4 z-[100] rounded p-4 text-white"
    >
      {error}{' '}
      <button
        disabled={retrying}
        className="underline"
        onClick={async () => {
          setRetrying(true)
          try {
            if (loaded) {
              await setProgress(progress)
              setError(null)
            } else {
              await check()
              await load()
            }
          } catch {
            setError(
              'Progress could not be saved. Keep this tab open and retry.'
            )
          } finally {
            setRetrying(false)
          }
        }}
      >
        {retrying ? 'Retrying…' : 'Retry'}
      </button>
    </div>
  )
}
