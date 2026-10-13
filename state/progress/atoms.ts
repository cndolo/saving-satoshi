import { setProgressLocal } from 'api/local'
import { setProgress } from 'api/progress'
import { atom } from 'jotai'
import { atomEffect } from 'jotai-effect'
import { CourseProgress } from 'types'
import { accountAtom, isAuthLoadingAtom } from '../state'
import { defaultProgressState } from './defaultProgress'

/**
 * Tracks whether a progress load/merge is currently running.
 *
 * This is mainly a UI spinner flag. It can be true even after we already
 * finished the first successful hydration.
 */
export const isLoadingProgressAtom = atom<boolean>(true)

/**
 * Tracks whether initial progress hydration has completed at least once.
 *
 * This is a sync-safety guard, not a loading spinner flag. We use it to avoid
 * writing default state back to storage before real progress has been loaded.
 */
export const isProgressLoadedAtom = atom<boolean>(false)

/** A visible error also prevents silently losing work during outages. */
export const progressErrorAtom = atom<string | null>(null)

/** Main in-memory source of truth for course progress. */
export const courseProgressAtom = atom<CourseProgress>(defaultProgressState)

/** Persist guest progress locally; student progress belongs only to the server account. */
const syncProgressEffectAtom = atomEffect((get, set) => {
  const account = get(accountAtom)
  const courseProgress = get(courseProgressAtom)
  const isAuthLoading = get(isAuthLoadingAtom)
  const isProgressLoaded = get(isProgressLoadedAtom)
  if (isAuthLoading || !isProgressLoaded) return

  if (account) {
    setProgress(courseProgress).catch(() => {
      if (get.peek(accountAtom)?.id === account.id) {
        set(
          progressErrorAtom,
          'Progress could not be saved. Keep this tab open and retry.'
        )
      }
    })
  } else {
    setProgressLocal(courseProgress)
  }
})

/**
 * Public progress atom that bundles state + sync behavior.
 *
 * Consumers read/write one atom, and persistence stays centralized here.
 */
export const syncedCourseProgressAtom = atom(
  (get) => {
    // Touching the effect atom wires up its reactive sync behavior.
    get(syncProgressEffectAtom)
    // Return the current in-memory progress snapshot.
    return get(courseProgressAtom)
  },
  (_get, set, update: Partial<CourseProgress>) => {
    // Accept partial updates so callers can set only what they care about.
    set(courseProgressAtom, (prev) => ({ ...prev, ...update }))
  }
)
