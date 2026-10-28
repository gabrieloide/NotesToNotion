import AVFoundation
import Foundation

enum LiveSenseiTest {
    static func runIfNeeded() {
        guard CommandLine.arguments.contains("--test-live-sensei") else { return }

        Task {
            do {
                try await executeTest()
                exit(0)
            } catch {
                print("ERROR: Prueba en vivo fallida: \(error)")
                exit(1)
            }
        }
    }

    private static func executeTest() async throws {
        print("INICIANDO PRUEBA EN VIVO DE GRABACION SENSEI")

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let systemURL = tempDir.appendingPathComponent("system-test.caf")
        let micURL = tempDir.appendingPathComponent("mic-test.m4a")
        let mixedURL = tempDir.appendingPathComponent("mixed-test.m4a")

        // 1. Iniciar grabador de audio del sistema para el canal Sensei
        let systemRecorder = SystemAudioRecorder(fileURL: systemURL)
        print("Iniciando SystemAudioRecorder...")
        try await systemRecorder.start()
        systemRecorder.synchronizeStartTime()

        // 2. Reproducir voz en japones con say
        print("Reproduciendo voz japonesa con comando say...")
        let speechProcess = Process()
        speechProcess.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        speechProcess.arguments = ["-v", "Kyoko", "こんにちは、先生です。今日の授業を始めましょう。"]
        try speechProcess.run()

        var maxSenseiLevel: Float = 0.0
        let startTime = Date()

        // Monitorear nivel de audio durante 5 segundos
        while Date().timeIntervalSince(startTime) < 5.0 {
            try await Task.sleep(nanoseconds: 100_000_000)
            let current = systemRecorder.currentLevel
            if current > maxSenseiLevel {
                maxSenseiLevel = current
            }
            if current > 0.05 {
                print(String(format: "Nivel en vivo de Sensei: %.3f", current))
            }
        }

        speechProcess.waitUntilExit()

        print("Deteniendo SystemAudioRecorder...")
        await systemRecorder.stop()

        // 1. Validar nivel maximo alcanzado
        print(String(format: "1. Nivel maximo alcanzado en barra Sensei: %.3f (requerido > 0.1)", maxSenseiLevel))
        guard maxSenseiLevel > 0.1 else {
            throw NSError(domain: "LiveTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "El nivel de Sensei no supero 0.1 (alcanzo \(maxSenseiLevel))."])
        }

        // 2. Validar archivo system-test.caf
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: systemURL.path)
        let fileSize = (fileAttributes[.size] as? Int64) ?? 0
        print("2. Tamano del archivo system-test.caf: \(fileSize) bytes (requerido > 100 KB)")

        let systemAudioFile = try AVAudioFile(forReading: systemURL)
        let frameCount = systemAudioFile.length
        print("   Total de frames de audio grabados en archivo CAF: \(frameCount)")

        guard fileSize > 100_000 else {
            throw NSError(domain: "LiveTest", code: 3, userInfo: [NSLocalizedDescriptionKey: "El tamano del archivo CAF es menor a 100 KB (\(fileSize) bytes)."])
        }
        guard frameCount > 0 else {
            throw NSError(domain: "LiveTest", code: 4, userInfo: [NSLocalizedDescriptionKey: "El archivo CAF contiene 0 frames."])
        }

        // 3. Crear archivo de microfono para mezcla dual-channel
        try createDummyMicFile(at: micURL, durationSeconds: 5.0)

        // 4. Mezclar pistas con AudioMixer
        print("Mezclando pistas con AudioMixer...")
        try AudioMixer.mix(micURL: micURL, systemURL: systemURL, outputURL: mixedURL)

        let mixedSize = (try? FileManager.default.attributesOfItem(atPath: mixedURL.path)[.size] as? Int64) ?? 0
        print("   Tamano del archivo mixto dual-channel: \(mixedSize) bytes")

        // 5. Transcribir con WhisperTranscriber
        print("Transcribiendo con WhisperTranscriber.shared...")
        let transcript = try await WhisperTranscriber.shared.transcribe(audioURL: mixedURL)
        print("RESULTADO DE TRANSCRIPCION:")
        print(transcript)

        guard transcript.contains("Sensei") else {
            throw NSError(domain: "LiveTest", code: 5, userInfo: [NSLocalizedDescriptionKey: "La transcripcion no contiene el identificador [Sensei]."])
        }
        guard transcript.contains("こんにちは") || transcript.contains("先生") else {
            throw NSError(domain: "LiveTest", code: 6, userInfo: [NSLocalizedDescriptionKey: "La transcripcion no identifico el texto en japones."])
        }

        print("PRUEBA EN VIVO EXITOSA AL 100%")
    }

    private static func createDummyMicFile(at url: URL, durationSeconds: Double) throws {
        let sampleRate = 44100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 48000,
            ]
        )
        let frameCount = AVAudioFrameCount(durationSeconds * sampleRate)
        let chunkSize: AVAudioFrameCount = 4096
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize)!
        buffer.frameLength = chunkSize
        if let data = buffer.floatChannelData?[0] {
            memset(data, 0, Int(chunkSize) * MemoryLayout<Float>.size)
        }
        var remaining = frameCount
        while remaining > 0 {
            let framesToWrite = min(remaining, chunkSize)
            buffer.frameLength = framesToWrite
            try file.write(from: buffer)
            remaining -= framesToWrite
        }
    }
}
