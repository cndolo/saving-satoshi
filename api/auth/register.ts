import { post } from 'utils'
import { getProgressLocal } from 'api/local'

export default async function register(privateKey: string, avatar: string) {
  const res = await post({
    url: '/v1/auth/register',
    body: {
      avatar,
      // Only a newly created account inherits the current guest progress.
      progress_state: await getProgressLocal(),
      private_key: privateKey,
    },
  })

  return res
}
