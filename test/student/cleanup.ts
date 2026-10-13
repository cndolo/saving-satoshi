import { rmSync } from 'fs'
import { basename } from 'path'
export default function cleanup() {
  const directory = process.env.STUDENT_TEST_DIR
  if (directory && basename(directory).startsWith('saving-satoshi-browser-')) {
    rmSync(directory, { recursive: true, force: true })
  }
}
