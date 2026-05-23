// Voice Activity Detection constants
pub const ASR_SAMPLE_RATE: u32 = 16000;
pub const VAD_FRAME_MS: u32 = 30;
pub const VAD_FRAME_SAMPLES: usize = (ASR_SAMPLE_RATE as usize) * VAD_FRAME_MS as usize / 1000;
pub const VAD_HYSTERESIS: f32 = 0.7;
pub const VAD_MIN_SILENCE_FRAMES: u32 = 20;
pub const VAD_MAX_SILENCE_FRAMES: u32 = 60;
pub const VAD_MIN_SPEECH_FRAMES: u32 = 3;
pub const CONTEXT_SAMPLES: usize = ASR_SAMPLE_RATE as usize * 300 / 1000; // 300ms context
pub const MAX_SEGMENT_SAMPLES: usize = ASR_SAMPLE_RATE as usize * 60;
pub const INTERIM_INTERVAL: u32 = 15;

/// Compute RMS energy of an audio frame
pub fn rms(samples: &[f32]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    let sum_sq: f32 = samples.iter().map(|s| s * s).sum();
    (sum_sq / samples.len() as f32).sqrt()
}

/// Simple resample by linear interpolation
pub fn resample_audio(input: &[f32], input_rate: u32, output_rate: u32) -> Vec<f32> {
    if input_rate == output_rate || input.is_empty() {
        return input.to_vec();
    }
    let ratio = output_rate as f64 / input_rate as f64;
    let output_len = (input.len() as f64 * ratio).ceil() as usize;
    let mut output = Vec::with_capacity(output_len);

    for i in 0..output_len {
        let src_pos = i as f64 / ratio;
        let src_idx = src_pos.floor() as usize;
        let frac = src_pos - src_idx as f64;

        let sample = if src_idx + 1 < input.len() {
            input[src_idx] * (1.0 - frac as f32) + input[src_idx + 1] * frac as f32
        } else if src_idx < input.len() {
            input[src_idx]
        } else {
            0.0
        };
        output.push(sample);
    }
    output
}

/// Detect whether a frame has speech activity
pub fn is_speech_active(
    energy: f32,
    threshold: f32,
    in_speech: bool,
    noise_floor: f32,
    suppress: bool,
) -> bool {
    let signal_ratio = energy / noise_floor.max(0.0001);
    let adjusted_energy = if suppress && signal_ratio < 0.3 {
        energy * 0.05
    } else {
        energy
    };

    if in_speech {
        adjusted_energy >= threshold * VAD_HYSTERESIS
    } else {
        adjusted_energy >= threshold
    }
}

/// Adaptive noise floor estimation
pub struct NoiseEstimator {
    pub raw: f32,
    pub floor: f32,
}

impl NoiseEstimator {
    pub fn new() -> Self {
        Self {
            raw: 0.01,
            floor: 0.01,
        }
    }

    pub fn update(&mut self, energy: f32, in_speech: bool) {
        if in_speech {
            self.raw = self.raw * 0.999 + 0.001 * self.raw.min(energy);
        } else {
            self.raw = self.raw * 0.98 + energy * 0.02;
        }
        self.floor = self.raw * 1.2;
    }
}

impl Default for NoiseEstimator {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_rms() {
        let samples = vec![1.0, -1.0, 1.0, -1.0];
        assert!((rms(&samples) - 1.0).abs() < 0.001);
    }

    #[test]
    fn test_resample_same_rate() {
        let input = vec![0.5; 100];
        let out = resample_audio(&input, 16000, 16000);
        assert_eq!(out.len(), 100);
    }

    #[test]
    fn test_resample_down() {
        let input = vec![0.0, 1.0, 0.0, 1.0];
        let out = resample_audio(&input, 16000, 8000);
        assert!(out.len() < input.len());
    }
}
