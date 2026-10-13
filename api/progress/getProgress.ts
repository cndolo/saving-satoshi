import { CourseProgress } from 'types'
import { get } from 'utils'

export default async function getProgress(): Promise<CourseProgress | null> {
  const res = await get({ url: '/v1/progress', includeToken: true })
  return res.progress_state
}
