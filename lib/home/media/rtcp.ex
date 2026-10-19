defmodule Home.Media.RTCP do
  @moduledoc """
  RTCP for media sessions (RFC 3550 reports, RFC 4585 feedback), multiplexed on the RTP
  socket pair (RFC 5761) in both directions:

    * the source sends sender reports (SR) on the RTP stream to every sink
      (`Home.Media.RTCP.Sender`);
    * each sink sends receiver reports (RR), generic NACKs and picture loss indications
      (PLI) back from its RTP port to the address the RTP comes from
      (`Home.Media.RTCP.Receiver`); the source retransmits NACKed packets from a short
      history and asks its encoder for a keyframe on a PLI.

  Both ends turn what they see into stats for `Home.Media.Session.stats/1`.
  """

  import Bitwise

  @ntp_epoch_offset 2_208_988_800

  @doc "Now as a 64-bit NTP timestamp."
  def ntp_now do
    us = :os.system_time(:microsecond)
    secs = div(us, 1_000_000) + @ntp_epoch_offset
    frac = div(rem(us, 1_000_000) <<< 32, 1_000_000)
    (secs <<< 32 ||| frac) &&& 0xFFFFFFFFFFFFFFFF
  end

  @doc "The middle 32 bits of an NTP timestamp (the LSR/DLSR format, 1/65536 s)."
  def middle32(ntp), do: ntp >>> 16 &&& 0xFFFFFFFF

  @doc "1/65536 s units to ms."
  def units_to_ms(units), do: units * 1_000 / 65_536

  @doc "ms to 1/65536 s units."
  def ms_to_units(ms), do: round(ms * 65_536 / 1_000)

  @doc "Is this datagram RTCP rather than RTP (RFC 5761 §4)?"
  def rtcp?(<<2::2, _::6, _marker::1, pt::7, _::binary>>), do: pt in 64..95
  def rtcp?(_), do: false
end
