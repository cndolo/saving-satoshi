import { useSetAtom } from 'jotai'
import { accountAtom, dataAtom, isAuthLoadingAtom } from './state'
import { login, getSession, logout } from 'api/auth'
import { SAVING_SATOSHI_TOKEN, SAVING_SATOSHI_PRIVATE_KEY } from 'config/keys'
import { defaultProgressState } from './progress/defaultProgress'
import {
  courseProgressAtom,
  isProgressLoadedAtom,
  isLoadingProgressAtom,
  progressErrorAtom,
} from './progress/atoms'
import { loadProgressAtom } from './progress/actions'
import { ApiError } from 'utils/fetch'
import { useRouter } from 'next/navigation'
import { useLocalizedRoutes } from 'hooks'

export const useAuthFunctions = () => {
  const setAccount = useSetAtom(accountAtom)
  const setData = useSetAtom(dataAtom)
  const router = useRouter()
  const routes = useLocalizedRoutes()
  const setAuthIsLoading = useSetAtom(isAuthLoadingAtom)
  const setCourseProgress = useSetAtom(courseProgressAtom)
  const setLoaded = useSetAtom(isProgressLoadedAtom)
  const setError = useSetAtom(progressErrorAtom)
  const setProgressLoading = useSetAtom(isLoadingProgressAtom)
  const loadProgress = useSetAtom(loadProgressAtom)

  const clearAccount = () => {
    for (const key of Object.keys(window.sessionStorage)) {
      if (key.startsWith('SavingSatoshiDraft:'))
        window.sessionStorage.removeItem(key)
    }
    window.sessionStorage.removeItem(SAVING_SATOSHI_TOKEN)
    window.sessionStorage.removeItem(SAVING_SATOSHI_PRIVATE_KEY)
    window.localStorage.removeItem(SAVING_SATOSHI_TOKEN) // remove legacy persistent tokens
    setAccount(undefined)
    setData([])
    setCourseProgress(defaultProgressState)
    setLoaded(false)
    setError(null)
  }

  const attemptLogin = async (privateKey: string) => {
    setAuthIsLoading(true)
    setProgressLoading(true)
    setLoaded(false)
    let succeeded = false
    try {
      await login(privateKey)
      const account = await getSession()
      setCourseProgress(defaultProgressState)
      setData([])
      setAccount(account)
      succeeded = true
      return true
    } catch {
      clearAccount()
      return false
    } finally {
      setAuthIsLoading(false)
      if (!succeeded) await loadProgress()
    }
  }

  const attemptLogout = async () => {
    setAuthIsLoading(true)
    setProgressLoading(true)
    try {
      await logout()
    } catch {
      // The local session is always cleared; server sessions also expire.
    } finally {
      clearAccount()
      setAuthIsLoading(false)
      await loadProgress()
      router.push(routes.chaptersUrl, { scroll: true })
    }
  }

  const check = async () => {
    setAuthIsLoading(true)
    window.localStorage.removeItem(SAVING_SATOSHI_TOKEN)
    try {
      if (window.sessionStorage.getItem(SAVING_SATOSHI_TOKEN)) {
        setAccount(await getSession())
      }
    } catch (error) {
      if (error instanceof ApiError && error.status === 401) {
        clearAccount()
      } else {
        // Keep the token on transient failures. Do not overwrite server state.
        setError('Account could not be loaded. Please reload to retry.')
      }
    } finally {
      setAuthIsLoading(false)
    }
  }

  return { attemptLogin, attemptLogout, check }
}
