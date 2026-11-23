// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include <chiaki/congestioncontrol.h>

#define CONGESTION_CONTROL_INTERVAL_MS 200

static void *congestion_control_thread_func(void *user)
{
	ChiakiCongestionControl *control = user;
	chiaki_thread_set_affinity(CHIAKI_THREAD_NAME_CONGESTION);

	ChiakiErrorCode err = chiaki_bool_pred_cond_lock(&control->stop_cond);
	if(err != CHIAKI_ERR_SUCCESS)
		return NULL;

	while(true)
	{
		err = chiaki_bool_pred_cond_timedwait(&control->stop_cond, CONGESTION_CONTROL_INTERVAL_MS);
		if(err != CHIAKI_ERR_TIMEOUT)
			break;

		uint64_t received;
		uint64_t lost;
		chiaki_packet_stats_get(control->stats, true, &received, &lost);
		ChiakiTakionCongestionPacket packet = { 0 };
		uint64_t total = received + lost;
		double raw_loss = total > 0 ? (double)lost / (double)total : 0.0;
		control->packet_loss = raw_loss;

		// Congestion Shield (EMA + single-window spike filter):
		// Ignore isolated 200 ms Wi-Fi micro-jitter spikes so PS5 doesn't crush bitrate/resolution,
		// while still reporting sustained congestion honestly.
		if(raw_loss > 0.005)
			control->consecutive_loss_windows++;
		else
			control->consecutive_loss_windows = 0;

		control->packet_loss_ema = control->packet_loss_ema * 0.65 + raw_loss * 0.35;
		double reported_loss = raw_loss;
		if(control->consecutive_loss_windows <= 1 && raw_loss < 0.25)
		{
			// Single brief jitter window: report smoothed EMA instead of the raw spike
			reported_loss = control->packet_loss_ema;
		}
		if(reported_loss > control->packet_loss_max)
		{
			CHIAKI_LOGD(control->takion->log, "Clamping reported packet loss: measured=%.1f%% filtered=%.1f%% reported_max=%.1f%%",
				raw_loss * 100.0, reported_loss * 100.0, control->packet_loss_max * 100.0);
			reported_loss = control->packet_loss_max;
		}
		if(total > 0)
		{
			lost = (uint64_t)((double)total * reported_loss + 0.5);
			if(lost > total)
				lost = total;
			received = total - lost;
		}
		packet.received = (uint16_t)received;
		packet.lost = (uint16_t)lost;
		CHIAKI_LOGV(control->takion->log, "Sending Congestion Control Packet, received: %u, lost: %u",
			(unsigned int)packet.received, (unsigned int)packet.lost);
		chiaki_takion_send_congestion(control->takion, &packet);
	}

	chiaki_bool_pred_cond_unlock(&control->stop_cond);
	return NULL;
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_congestion_control_start(ChiakiCongestionControl *control, ChiakiTakion *takion, ChiakiPacketStats *stats, double packet_loss_max)
{
	control->takion = takion;
	control->stats = stats;
	control->packet_loss_max = packet_loss_max;
	control->packet_loss = 0;
	control->packet_loss_ema = 0;
	control->consecutive_loss_windows = 0;

	ChiakiErrorCode err = chiaki_bool_pred_cond_init(&control->stop_cond);
	if(err != CHIAKI_ERR_SUCCESS)
		return err;

	err = chiaki_thread_create(&control->thread, congestion_control_thread_func, control);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		chiaki_bool_pred_cond_fini(&control->stop_cond);
		return err;
	}

	chiaki_thread_set_name(&control->thread, "Chiaki Congestion Control");

	return CHIAKI_ERR_SUCCESS;
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_congestion_control_stop(ChiakiCongestionControl *control)
{
	ChiakiErrorCode err = chiaki_bool_pred_cond_signal(&control->stop_cond);
	if(err != CHIAKI_ERR_SUCCESS)
		return err;

	err = chiaki_thread_join(&control->thread, NULL);
	if(err != CHIAKI_ERR_SUCCESS)
		return err;
	control->thread.thread = 0;

	return chiaki_bool_pred_cond_fini(&control->stop_cond);
}
