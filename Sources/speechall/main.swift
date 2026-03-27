import SpeechallCLI

@main
enum SpeechallExecutable {
    static func main() async {
        await Speechall.main()
    }
}
