// Test-only bridge. There is no fallback to a real adb/fastboot executable.
using System;
using System.Diagnostics;
using System.IO;
using System.Text.RegularExpressions;
class MockTool {
    static string Quote(string s) {
        return "\"" + Regex.Replace(Regex.Replace(s, "(\\\\*)\"", "$1$1\\\""), "(\\\\+)$", "$1$1") + "\"";
    }
    static int Main(string[] args) {
        if (args.Length > 0 && args[0] == "test-timeout") { System.Threading.Thread.Sleep(60000); return 0; }
        var python = Environment.GetEnvironmentVariable("FUXI_TEST_PYTHON");
        var mock = Environment.GetEnvironmentVariable("FUXI_TEST_MOCK");
        if (String.IsNullOrEmpty(python) || String.IsNullOrEmpty(mock)) return 90;
        var kind = Path.GetFileNameWithoutExtension(Process.GetCurrentProcess().MainModule.FileName);
        var start = new ProcessStartInfo(python, Quote(mock) + " " + Quote(kind));
        foreach (var arg in args) start.Arguments += " " + Quote(arg);
        start.UseShellExecute = false;
        start.CreateNoWindow = true;
        start.RedirectStandardOutput = true;
        start.RedirectStandardError = true;
        using (var p = Process.Start(start)) {
            var output = p.StandardOutput.ReadToEndAsync();
            var error = p.StandardError.ReadToEndAsync();
            p.WaitForExit();
            Console.Out.Write(output.Result);
            Console.Error.Write(error.Result);
            return p.ExitCode;
        }
    }
}
