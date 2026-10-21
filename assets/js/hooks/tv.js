// Host-screen hooks (the host screen, HostLive, is also the TV display).
//
// The music hooks live in ./music/ — a provider-neutral `MusicPlayer` hook plus
// one small module per music provider. The "Countdown" hook lives in
// hooks/player.js and is registered globally, so host-screen templates using
// phx-hook="Countdown" pick it up from there (its mm:ss + stop-at-zero
// rendering is fine on the TV).

import music from "./music"

export default {...music}
