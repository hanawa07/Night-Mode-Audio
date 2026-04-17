import AudioToolbox
import CoreAudio
import Foundation

public final class PassThroughEngine {
    private var inputUnit: AudioUnit?
    private var outputUnit: AudioUnit?
    private var streamFormat = AudioStreamBasicDescription()
    private var renderInvocationCount: UInt64 = 0
    private var captureInvocationCount: UInt64 = 0
    private let ringLock = NSLock()
    private var ringBuffers: [[Float]] = []
    private var ringCapacityFrames = 0
    private var ringReadIndex = 0
    private var ringWriteIndex = 0
    private var ringAvailableFrames = 0
    private var targetLatencyFrames = 0
    private var maxLatencyFrames = 0
    private var minimumStartFrames = 0
    private var latencyClampLogCounter: UInt64 = 0
    private let latencyMode: LatencyMode
    private let dynamicsLock = NSLock()
    private var thresholdDB: Float = -20.0
    private var makeupGainDB: Float = 10.0
    private var ratio: Float = 4.0

    public init(
        inputDeviceID: AudioDeviceID,
        outputDeviceID: AudioDeviceID,
        latencyMode: LatencyMode = .balanced,
        thresholdDB: Float = -20.0,
        makeupGainDB: Float = 10.0,
        ratio: Float = 4.0
    ) throws {
        self.latencyMode = latencyMode
        self.thresholdDB = thresholdDB
        self.makeupGainDB = makeupGainDB
        self.ratio = ratio
        try setupInputUnit(deviceID: inputDeviceID)
        try setupOutputUnit(deviceID: outputDeviceID)
    }

    deinit {
        stop()
    }

    public func start() throws {
        guard let inputUnit, let outputUnit else { return }
        print("입력 포맷: \(describe(streamFormat))")
        try check(AudioOutputUnitStart(inputUnit), context: "입력 유닛 시작")
        try check(AudioOutputUnitStart(outputUnit), context: "출력 유닛 시작")
        print("오디오 엔진 시작 완료")
    }

    public func stop() {
        if let inputUnit {
            AudioOutputUnitStop(inputUnit)
            AudioUnitUninitialize(inputUnit)
            AudioComponentInstanceDispose(inputUnit)
            self.inputUnit = nil
        }
        if let outputUnit {
            AudioOutputUnitStop(outputUnit)
            AudioUnitUninitialize(outputUnit)
            AudioComponentInstanceDispose(outputUnit)
            self.outputUnit = nil
        }
    }

    public func configureDynamics(thresholdDB: Float, makeupGainDB: Float, ratio: Float) {
        dynamicsLock.lock()
        self.thresholdDB = thresholdDB
        self.makeupGainDB = makeupGainDB
        self.ratio = ratio
        dynamicsLock.unlock()
    }

    private func setupInputUnit(deviceID: AudioDeviceID) throws {
        let unit = try createHALUnit()

        var enableIO: UInt32 = 1
        var disableIO: UInt32 = 0
        try check(
            AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Input,
                1,
                &enableIO,
                UInt32(MemoryLayout<UInt32>.size)
            ),
            context: "입력 유닛 input enable"
        )
        try check(
            AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Output,
                0,
                &disableIO,
                UInt32(MemoryLayout<UInt32>.size)
            ),
            context: "입력 유닛 output disable"
        )

        var mutableDeviceID = deviceID
        try check(
            AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &mutableDeviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            ),
            context: "입력 유닛 장치 설정"
        )

        var deviceFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioUnitGetProperty(
                unit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Input,
                1,
                &deviceFormat,
                &size
            ),
            context: "입력 디바이스 포맷 조회"
        )

        var desiredFormat = makeCanonicalFloatFormat(
            sampleRate: deviceFormat.mSampleRate,
            channels: deviceFormat.mChannelsPerFrame
        )
        try check(
            AudioUnitSetProperty(
                unit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output,
                1,
                &desiredFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            ),
            context: "입력 유닛 클라이언트 포맷 설정"
        )

        try check(AudioUnitInitialize(unit), context: "입력 유닛 초기화")

        var format = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioUnitGetProperty(
                unit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output,
                1,
                &format,
                &size
            ),
            context: "입력 유닛 클라이언트 포맷 조회"
        )

        inputUnit = unit
        streamFormat = format
        configureRingBuffer()

        var callback = AURenderCallbackStruct(
            inputProc: { inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, _ in
                let engine = Unmanaged<PassThroughEngine>.fromOpaque(inRefCon).takeUnretainedValue()
                guard let inputUnit = engine.inputUnit else {
                    return noErr
                }
                return engine.captureInput(
                    from: inputUnit,
                    ioActionFlags: ioActionFlags,
                    inTimeStamp: inTimeStamp,
                    inBusNumber: inBusNumber,
                    inNumberFrames: inNumberFrames
                )
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        try check(
            AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_SetInputCallback,
                kAudioUnitScope_Global,
                0,
                &callback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ),
            context: "입력 유닛 입력 콜백 설정"
        )
    }

    private func setupOutputUnit(deviceID: AudioDeviceID) throws {
        let unit = try createHALUnit()

        var enableIO: UInt32 = 1
        var disableIO: UInt32 = 0
        try check(
            AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Output,
                0,
                &enableIO,
                UInt32(MemoryLayout<UInt32>.size)
            ),
            context: "출력 유닛 output enable"
        )
        try check(
            AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Input,
                1,
                &disableIO,
                UInt32(MemoryLayout<UInt32>.size)
            ),
            context: "출력 유닛 input disable"
        )

        var mutableDeviceID = deviceID
        try check(
            AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &mutableDeviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            ),
            context: "출력 유닛 장치 설정"
        )

        var outputFormat = streamFormat
        try check(
            AudioUnitSetProperty(
                unit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Input,
                0,
                &outputFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            ),
            context: "출력 유닛 포맷 설정"
        )

        var callback = AURenderCallbackStruct(
            inputProc: { inRefCon, _, _, inBusNumber, inNumberFrames, ioData in
                guard let ioData else {
                    return noErr
                }

                let engine = Unmanaged<PassThroughEngine>.fromOpaque(inRefCon).takeUnretainedValue()
                engine.renderInvocationCount += 1
                if engine.renderInvocationCount == 1 {
                    print("첫 렌더 콜백 수신: frames=\(inNumberFrames) bus=\(inBusNumber)")
                }

                engine.renderOutput(into: ioData, frameCount: Int(inNumberFrames))
                return noErr
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        try check(
            AudioUnitSetProperty(
                unit,
                kAudioUnitProperty_SetRenderCallback,
                kAudioUnitScope_Input,
                0,
                &callback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ),
            context: "출력 유닛 렌더 콜백 설정"
        )

        try check(AudioUnitInitialize(unit), context: "출력 유닛 초기화")

        outputUnit = unit
    }

    private func createHALUnit() throws -> AudioUnit {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &description) else {
            throw PassThroughError.componentMissing
        }

        var unit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &unit), context: "HAL 유닛 생성")
        guard let unit else {
            throw PassThroughError.componentMissing
        }
        return unit
    }

    private func check(_ status: OSStatus, context: String) throws {
        guard status == noErr else {
            throw PassThroughError.osStatus(status, context)
        }
    }

    private func configureRingBuffer() {
        let channelCount = Int(streamFormat.mChannelsPerFrame)
        switch latencyMode {
        case .stable:
            ringCapacityFrames = max(Int(streamFormat.mSampleRate * 0.16), 2048)
            targetLatencyFrames = max(Int(streamFormat.mSampleRate * 0.006), 288)
            maxLatencyFrames = max(Int(streamFormat.mSampleRate * 0.014), targetLatencyFrames * 2)
            minimumStartFrames = max(targetLatencyFrames / 2, 128)
        case .balanced:
            ringCapacityFrames = max(Int(streamFormat.mSampleRate * 0.12), 2048)
            targetLatencyFrames = max(Int(streamFormat.mSampleRate * 0.005), 240)
            maxLatencyFrames = max(Int(streamFormat.mSampleRate * 0.012), targetLatencyFrames * 2)
            minimumStartFrames = max(targetLatencyFrames / 2, 96)
        case .lowLatency:
            ringCapacityFrames = max(Int(streamFormat.mSampleRate * 0.10), 1536)
            targetLatencyFrames = max(Int(streamFormat.mSampleRate * 0.0045), 216)
            maxLatencyFrames = max(Int(streamFormat.mSampleRate * 0.010), targetLatencyFrames * 2)
            minimumStartFrames = max(targetLatencyFrames / 2, 96)
        }
        ringBuffers = Array(
            repeating: Array(repeating: 0, count: ringCapacityFrames),
            count: max(channelCount, 1)
        )
        ringReadIndex = 0
        ringWriteIndex = 0
        ringAvailableFrames = 0
        print("버퍼 설정[\(latencyMode.rawValue)]: capacity=\(ringCapacityFrames) start=\(minimumStartFrames) target=\(targetLatencyFrames) max=\(maxLatencyFrames)")
    }

    private func captureInput(
        from unit: AudioUnit,
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        inTimeStamp: UnsafePointer<AudioTimeStamp>,
        inBusNumber: UInt32,
        inNumberFrames: UInt32
    ) -> OSStatus {
        let channelCount = max(Int(streamFormat.mChannelsPerFrame), 1)
        let bytesPerSample = MemoryLayout<Float>.size
        let byteCount = Int(inNumberFrames) * bytesPerSample
        let allocatedBufferList = allocateAudioBufferList(maximumBuffers: channelCount)
        let bufferList = allocatedBufferList.bufferList
        defer {
            for buffer in bufferList {
                free(buffer.mData)
            }
            allocatedBufferList.rawPointer.deallocate()
        }

        for index in 0..<channelCount {
            bufferList[index] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(byteCount),
                mData: calloc(Int(inNumberFrames), bytesPerSample)
            )
        }

        let status = AudioUnitRender(
            unit,
            ioActionFlags,
            inTimeStamp,
            inBusNumber,
            inNumberFrames,
            bufferList.unsafeMutablePointer
        )
        if status != noErr {
            fputs("입력 캡처 실패: OSStatus \(status)\n", stderr)
            return status
        }

        captureInvocationCount += 1
        if captureInvocationCount == 1 {
            print("첫 입력 콜백 수신: frames=\(inNumberFrames) bus=\(inBusNumber)")
        }

        storeCapturedFrames(bufferList: bufferList, frameCount: Int(inNumberFrames))
        return noErr
    }

    private func storeCapturedFrames(
        bufferList: UnsafeMutableAudioBufferListPointer,
        frameCount: Int
    ) {
        applyDynamics(to: bufferList, frameCount: frameCount)

        ringLock.lock()
        defer { ringLock.unlock() }

        let channelsToCopy = min(bufferList.count, ringBuffers.count)
        for frame in 0..<frameCount {
            let destinationIndex = (ringWriteIndex + frame) % ringCapacityFrames
            for channel in 0..<channelsToCopy {
                guard let data = bufferList[channel].mData else { continue }
                let source = data.assumingMemoryBound(to: Float.self)
                ringBuffers[channel][destinationIndex] = source[frame]
            }
        }

        let writableFrames = min(frameCount, ringCapacityFrames)
        if writableFrames >= ringCapacityFrames {
            ringReadIndex = 0
            ringWriteIndex = 0
            ringAvailableFrames = ringCapacityFrames
            return
        }

        let overflow = max(0, ringAvailableFrames + writableFrames - ringCapacityFrames)
        if overflow > 0 {
            ringReadIndex = (ringReadIndex + overflow) % ringCapacityFrames
            ringAvailableFrames -= overflow
        }

        ringWriteIndex = (ringWriteIndex + writableFrames) % ringCapacityFrames
        ringAvailableFrames += writableFrames

        if ringAvailableFrames > maxLatencyFrames {
            let framesToDrop = ringAvailableFrames - targetLatencyFrames
            ringReadIndex = (ringReadIndex + framesToDrop) % ringCapacityFrames
            ringAvailableFrames -= framesToDrop
            latencyClampLogCounter += 1
            if latencyClampLogCounter <= 5 || latencyClampLogCounter.isMultiple(of: 200) {
                print("지연 보정: \(framesToDrop)프레임 폐기, 현재 버퍼=\(ringAvailableFrames)")
            }
        }
    }

    private func renderOutput(
        into ioData: UnsafeMutablePointer<AudioBufferList>,
        frameCount: Int
    ) {
        let bufferList = UnsafeMutableAudioBufferListPointer(ioData)

        ringLock.lock()
        let availableFrames = ringAvailableFrames
        let readableFrames = availableFrames >= minimumStartFrames
            ? min(frameCount, availableFrames)
            : 0
        let startReadIndex = ringReadIndex
        if readableFrames > 0 {
            ringReadIndex = (ringReadIndex + readableFrames) % ringCapacityFrames
            ringAvailableFrames -= readableFrames
        }
        ringLock.unlock()

        for channel in 0..<bufferList.count {
            guard let data = bufferList[channel].mData else { continue }
            let destination = data.assumingMemoryBound(to: Float.self)

            if channel < ringBuffers.count, readableFrames > 0 {
                for frame in 0..<readableFrames {
                    let sourceIndex = (startReadIndex + frame) % ringCapacityFrames
                    destination[frame] = ringBuffers[channel][sourceIndex]
                }
            }

            if readableFrames < frameCount {
                for frame in readableFrames..<frameCount {
                    destination[frame] = 0
                }
            }

            bufferList[channel].mDataByteSize = UInt32(frameCount * MemoryLayout<Float>.size)
        }
    }

    private func describe(_ format: AudioStreamBasicDescription) -> String {
        "sampleRate=\(format.mSampleRate) channels=\(format.mChannelsPerFrame) bits=\(format.mBitsPerChannel) bytesPerFrame=\(format.mBytesPerFrame) framesPerPacket=\(format.mFramesPerPacket) formatID=\(format.mFormatID) flags=\(format.mFormatFlags)"
    }

    private func applyDynamics(
        to bufferList: UnsafeMutableAudioBufferListPointer,
        frameCount: Int
    ) {
        let channelCount = min(bufferList.count, ringBuffers.count)
        guard channelCount > 0, frameCount > 0 else {
            return
        }

        var sumSquares: Float = 0
        var sampleCount = 0
        for channel in 0..<channelCount {
            guard let data = bufferList[channel].mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<frameCount {
                let sample = samples[frame]
                sumSquares += sample * sample
                sampleCount += 1
            }
        }

        guard sampleCount > 0 else {
            return
        }

        let rms = max(sqrt(sumSquares / Float(sampleCount)), 1e-9)
        let currentDB = 20.0 * log10(rms)

        dynamicsLock.lock()
        let thresholdDB = self.thresholdDB
        let makeupGainDB = self.makeupGainDB
        let ratio = self.ratio
        dynamicsLock.unlock()

        var gainReductionDB: Float = 0
        if currentDB > thresholdDB {
            let overshoot = currentDB - thresholdDB
            let targetDB = thresholdDB + (overshoot / max(ratio, 1.0))
            gainReductionDB = currentDB - targetDB
        }

        let totalGainDB = makeupGainDB - gainReductionDB
        let linearGain = pow(10.0, totalGainDB / 20.0)

        for channel in 0..<channelCount {
            guard let data = bufferList[channel].mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<frameCount {
                let processed = samples[frame] * linearGain
                samples[frame] = min(max(processed, -1.0), 1.0)
            }
        }
    }
}
