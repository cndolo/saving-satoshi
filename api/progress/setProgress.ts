import { CourseProgress } from 'types'
import { put } from 'utils'
import { SAVING_SATOSHI_TOKEN } from 'config/keys'

// Serialize snapshots so a slower old request cannot overwrite a newer one.
let pending: Promise<void> = Promise.resolve()

export default function setProgress(progress: CourseProgress): Promise<void> {
  const token = window.sessionStorage.getItem(SAVING_SATOSHI_TOKEN)
  const snapshot = JSON.parse(JSON.stringify(progress))
  const write = pending
    .catch(() => {})
    .then(async () => {
      // Discard queued snapshots after logout/account changes. In-flight requests
      // carry the captured token and can only affect its original account.
      if (
        !token ||
        window.sessionStorage.getItem(SAVING_SATOSHI_TOKEN) !== token
      )
        return
      await put({
        url: '/v1/progress',
        headers: { Authorization: `Bearer ${token}` },
        body: { progress_state: snapshot },
      })
    })
  pending = write
  return write
}
