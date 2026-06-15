// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import 'phoenix_html'
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from 'phoenix'
import { LiveSocket } from 'phoenix_live_view'
import topbar from '../vendor/topbar'
import Alpine from 'alpinejs'
import './tabs'
import './alpine_helpers'

window.Alpine = Alpine
Alpine.start()

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute('content')
let liveSocket = new LiveSocket(document.body.dataset.socketPath, Socket, {
  params: { _csrf_token: csrfToken },
  dom: {
    onBeforeElUpdated(from, to) {
      if (from._x_dataStack) {
        window.Alpine.clone(from, to)
      }
    }
  },
  hooks: {
    'supress-enter-submission': {
      mounted() {
        this.el.addEventListener('keypress', (event) => {
          if (event.key === 'Enter') {
            event.preventDefault()
          }
        })
      }
    },
    // Live ticking countdown to a media item's next retry time. The target time comes from the
    // server as an ISO-8601 timestamp in data-retry-at; we compute the remaining time on the
    // CLIENT every second so it doesn't depend on the (often-wrong) container clock. When the
    // time is reached we show "due now" — the server will pick the job up on its next poll and a
    // table refresh will move the item out of the Retry tab.
    RetryCountdown: {
      mounted() {
        this.render()
        this.timer = setInterval(() => this.render(), 1000)
      },
      updated() {
        this.render()
      },
      destroyed() {
        if (this.timer) clearInterval(this.timer)
      },
      render() {
        const retryAt = this.el.dataset.retryAt
        if (!retryAt) {
          this.el.textContent = 'queued'
          return
        }

        const diffMs = new Date(retryAt).getTime() - Date.now()
        if (isNaN(diffMs)) {
          this.el.textContent = ''
          return
        }
        if (diffMs <= 0) {
          this.el.textContent = 'due now'
          return
        }

        let secs = Math.floor(diffMs / 1000)
        const h = Math.floor(secs / 3600)
        secs -= h * 3600
        const m = Math.floor(secs / 60)
        const s = secs - m * 60

        const parts = []
        if (h > 0) parts.push(h + 'h')
        if (h > 0 || m > 0) parts.push(m + 'm')
        parts.push(s + 's')

        this.el.textContent = 'in ' + parts.join(' ')
      }
    }
  }
})

// Show progress bar on live navigation and form submits
topbar.config({ barColors: { 0: '#29d' }, shadowColor: 'rgba(0, 0, 0, .3)' })
window.addEventListener('phx:page-loading-start', (_info) => topbar.show(300))
window.addEventListener('phx:page-loading-stop', (_info) => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket
