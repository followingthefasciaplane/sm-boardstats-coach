#if defined _momsurffix2_included
	#endinput
#endif
#define _momsurffix2_included
#define MOMSURFFIX2_API_VERSION 3

/** ========================================================================= */

/**
 * usage:
 * 
 * #undef REQUIRE_PLUGIN
 * #include <momsurffix2>
 */

/** ========================================================================= */

/**
 * reasons why the player is stuck on a ramp
 */
enum MomSurfFixStuckReason
{
	/**
	 * trace inconsistent, force re-calculate ramp plane.
	 */
	MomSurfFixStuck_InvalidTrace = 0,
	/**
	 * the very first trace of the frame reported the player starting in solid
	 */
	MomSurfFixStuck_TraceStartSolid,
};

/** ========================================================================= */

/**
 * step phases
 */
enum MomSurfFixStepPhase
{
	/** regular (no step tracing) */
	MomSurfFixStep_Normal = 0,
	/** the downward StepMove TryPlayerMove pass that reuses the first trace */
	MomSurfFixStep_StepMoveDown,
	/** the upward StepMove TryPlayerMove pass that follows the down sweep */
	MomSurfFixStep_StepMoveUp,
};

/** ========================================================================= */

/**
 * called on ClipVelocity for a client.
 *
 * @param client			player index.
 * @param tickCount			game tick from GetGameTickCount().
 * @param callSerial		zero-based TryPlayerMove call index for this tick.
 * @param stepPhase			StepMove phase (normal/down/up) for the call.
 * @param inVel				velocity before clipping.
 * @param planeNormal		plane normal used for the clip.
 * @param outVel			resulting velocity after clipping.
 * @param overbounce		the overbounce scalar passed to ClipVelocity.
 */
forward void MomSurfFix_OnClipVelocity(int client, int tickCount, int callSerial, MomSurfFixStepPhase stepPhase, const float inVel[3], const float planeNormal[3], const float outVel[3], float overbounce);

/** ========================================================================= */

/**
 * fired when the player will be stuck on a ramp.
 *
 * @param client			player index.
 * @param tickCount			game tick from GetGameTickCount().
 * @param callSerial		zero-based TryPlayerMove call index for this tick.
 * @param stepPhase			StepMove phase (normal/down/up) for the call.
 * @param iteration			iteration where the failure was detected.
 * @param reason			stuck reason from MomSurfFixStuckReason.
 * @param velocity			velocity right before forcing the recovery.
 * @param origin			origin sampled for the recovery trace.
 * @param hadValidPlane		true if a valid plane was available prior to the event.
 * @param candidatePlane	last known plane normal (may be zeroed if invalid).
 */
forward void MomSurfFix_OnPlayerStuckOnRamp(int client, int tickCount, int callSerial, MomSurfFixStepPhase stepPhase, int iteration, MomSurfFixStuckReason reason, const float velocity[3], const float origin[3], bool hadValidPlane, const float candidatePlane[3]);

/** ========================================================================= */

/**
 * fired at the end of TryPlayerMove.
 *
 * @param client			player index.
 * @param tickCount			game tick from GetGameTickCount().
 * @param callSerial		zero-based TryPlayerMove call index for this tick.
 * @param stepPhase			StepMove phase (normal/down/up) for the call.
 * @param blockedMask		blocked flags.
 * @param lastIteration		last iteration that was executed (zero-based).
 * @param maxIterations		configured bumpcount.
 * @param finalVelocity		final velocity after the move completed.
 * @param finalOrigin		final origin after the move completed.
 * @param stuckOnRamp		true if MomSurfFix2 ended in ramp recovery mode.
 * @param hasValidPlane		true if the returned plane normal is valid. only valid during ramp recovery
 * @param finalPlane		best known plane normal at the end of the move. only valid if hasValidPlane is true
 * @param totalFraction		total fraction of the wish movement that could be resolved. sum of trace fractions
 */
forward void MomSurfFix_OnTryPlayerMovePost(int client, int tickCount, int callSerial, MomSurfFixStepPhase stepPhase, int blockedMask, int lastIteration, int maxIterations, const float finalVelocity[3], const float finalOrigin[3], bool stuckOnRamp, bool hasValidPlane, const float finalPlane[3], float totalFraction);

/** ========================================================================= */

#if !defined MOMSURFFIX2_CORE
public SharedPlugin __pl_momsurffix2 =
{
	name = "momsurffix2",
	file = "momsurffix2.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_momsurffix2_SetNTVOptional()
{
}
#endif

#endif
