package com.example.filament_widget

import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

class OrbitCameraController {
    var yawDeg = 0.0
        private set
    var pitchDeg = 0.0
        private set
    var distance = 3.0
        private set
    var minYawDeg = -180.0
    var maxYawDeg = 180.0
    var minPitchDeg = -89.0
    var maxPitchDeg = 89.0
    var minDistance = 0.05
    var maxDistance = 100.0
    var inertiaEnabled = true
    var damping = 0.9
    var sensitivity = 0.15

    private var velocityYaw = 0.0
    private var velocityPitch = 0.0
    private var lastFrameTimeNanos = 0L

    var targetX = 0.0
    var targetY = 0.0
    var targetZ = 0.0

    fun reset(frameDistance: Double, target: DoubleArray) {
        distance = frameDistance.coerceIn(minDistance, maxDistance)
        yawDeg = 0.0
        pitchDeg = 0.0
        targetX = target[0]
        targetY = target[1]
        targetZ = target[2]
        velocityYaw = 0.0
        velocityPitch = 0.0
    }

    fun setOrbitConstraints(minPitch: Double, maxPitch: Double, minYaw: Double, maxYaw: Double) {
        minPitchDeg = minPitch
        maxPitchDeg = maxPitch
        minYawDeg = minYaw
        maxYawDeg = maxYaw
        clampAngles()
    }

    fun setZoomLimits(minDistance: Double, maxDistance: Double) {
        this.minDistance = minDistance
        this.maxDistance = maxDistance
        distance = distance.coerceIn(minDistance, maxDistance)
    }

    fun orbitStart() {
        velocityYaw = 0.0
        velocityPitch = 0.0
    }

    fun orbitDelta(dxPixels: Double, dyPixels: Double) {
        yawDeg -= dxPixels * sensitivity
        pitchDeg += dyPixels * sensitivity
        clampAngles()
    }

    fun orbitEnd(velocityX: Double, velocityY: Double) {
        if (!inertiaEnabled) {
            velocityYaw = 0.0
            velocityPitch = 0.0
            return
        }
        velocityYaw = -velocityX * sensitivity
        velocityPitch = velocityY * sensitivity
    }

    fun zoomDelta(scaleDelta: Double) {
        if (scaleDelta <= 0.0) {
            return
        }
        distance = (distance / scaleDelta).coerceIn(minDistance, maxDistance)
    }

    fun update(frameTimeNanos: Long) {
        if (lastFrameTimeNanos == 0L) {
            lastFrameTimeNanos = frameTimeNanos
            return
        }
        val deltaSeconds = (frameTimeNanos - lastFrameTimeNanos) / 1_000_000_000.0
        lastFrameTimeNanos = frameTimeNanos
        if (!inertiaEnabled) {
            return
        }
        if (abs(velocityYaw) < 0.0001 && abs(velocityPitch) < 0.0001) {
            velocityYaw = 0.0
            velocityPitch = 0.0
            return
        }
        yawDeg += velocityYaw * deltaSeconds
        pitchDeg += velocityPitch * deltaSeconds
        clampAngles()
        val decay = damping.pow(deltaSeconds * 60.0)
        velocityYaw *= decay
        velocityPitch *= decay
    }

    fun getEyePosition(out: DoubleArray) {
        require(out.size >= 3) { "Output array must have at least 3 elements" }
        val yawRad = Math.toRadians(yawDeg)
        val pitchRad = Math.toRadians(pitchDeg)
        val cosPitch = cos(pitchRad)
        val sinPitch = sin(pitchRad)
        val sinYaw = sin(yawRad)
        val cosYaw = cos(yawRad)
        val x = distance * cosPitch * sinYaw
        val y = distance * sinPitch
        val z = distance * cosPitch * cosYaw
        out[0] = targetX + x
        out[1] = targetY + y
        out[2] = targetZ + z
    }

    fun setTarget(x: Double, y: Double, z: Double) {
        targetX = x
        targetY = y
        targetZ = z
    }

    fun computeDistanceForRadius(radius: Double, fovDegrees: Double): Double {
        val fovRadians = Math.toRadians(fovDegrees)
        val halfFov = max(0.01, fovRadians * 0.5)
        val minDistance = radius / sin(halfFov)
        return max(minDistance, 0.05)
    }

    fun updateTargetFromBounds(center: DoubleArray, halfExtent: DoubleArray): Double {
        val radius = sqrt(
            halfExtent[0] * halfExtent[0] +
                halfExtent[1] * halfExtent[1] +
                halfExtent[2] * halfExtent[2],
        )
        setTarget(center[0], center[1], center[2])
        return max(radius, 0.05)
    }

    private fun clampAngles() {
        yawDeg = yawDeg.coerceIn(minYawDeg, maxYawDeg)
        pitchDeg = pitchDeg.coerceIn(minPitchDeg, maxPitchDeg)
    }
}
