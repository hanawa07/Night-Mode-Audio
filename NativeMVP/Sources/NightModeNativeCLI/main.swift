import Foundation
import NightModeNativeCore

func printUsage() {
    print("""
    NightModeNativeMVP

    사용법:
      swift run NightModeNativeMVP list
      swift run NightModeNativeMVP probe
      swift run NightModeNativeMVP passthrough <output-uid>
    """)
}

func runList() {
    let devices = listDevices()
    if devices.isEmpty {
        print("장치를 찾지 못했습니다.")
        return
    }

    for device in devices {
        print(device.description)
    }
}

func runProbe() {
    let devices = listDevices()
    let blackhole = devices.first { $0.hasInput && $0.name.contains("BlackHole") }
    let outputs = devices.filter { $0.hasOutput && !$0.name.contains("BlackHole") }

    print("입력 후보:")
    if let blackhole {
        print("  \(blackhole.description)")
    } else {
        print("  BlackHole 입력 장치를 찾지 못했습니다.")
    }

    print("출력 후보:")
    if outputs.isEmpty {
        print("  출력 장치가 없습니다.")
    } else {
        for device in outputs {
            print("  \(device.description)")
        }
    }

    print("")
    print("probe는 장치 탐지 검증용입니다.")
    print("패스스루 실행은: swift run NightModeNativeMVP passthrough <output-uid>")
}

func runPassThrough(outputUID: String) {
    let devices = listDevices()
    guard let input = devices.first(where: { $0.hasInput && $0.name.contains("BlackHole") }) else {
        fputs("\(PassThroughError.blackHoleMissing)\n", stderr)
        exit(1)
    }
    guard let output = devices.first(where: { $0.uid == outputUID && $0.hasOutput }) else {
        fputs("\(PassThroughError.outputMissing(outputUID))\n", stderr)
        exit(1)
    }

    print("입력: \(input.description)")
    print("출력: \(output.description)")
    if let defaultOutputID = readDefaultOutputDeviceID(),
       let defaultOutput = devices.first(where: { $0.id == defaultOutputID }) {
        print("현재 macOS 기본 출력: \(defaultOutput.description)")
        if defaultOutput.uid != input.uid {
            print("경고: 시스템 기본 출력이 BlackHole이 아닙니다. 이 상태에선 패스스루로 들을 소리가 안 들어올 수 있습니다.")
        }
    }
    print("엔진 시작 중... 종료하려면 Ctrl+C")

    do {
        let engine = try PassThroughEngine(inputDeviceID: input.id, outputDeviceID: output.id)
        try engine.start()
        RunLoop.current.run()
    } catch {
        fputs("패스스루 시작 실패: \(error)\n", stderr)
        exit(1)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    printUsage()
    exit(0)
}

switch command {
case "list":
    runList()
case "probe":
    runProbe()
case "passthrough":
    guard arguments.count >= 2 else {
        printUsage()
        exit(1)
    }
    runPassThrough(outputUID: arguments[1])
default:
    printUsage()
}
