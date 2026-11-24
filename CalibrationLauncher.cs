using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

internal static class CalibrationLauncher
{
    [STAThread]
    private static int Main()
    {
        try
        {
            string folder = AppDomain.CurrentDomain.BaseDirectory;
            string script = Path.Combine(folder, "calibration_gui.ps1");
            string tool = Path.Combine(folder, "runtime", "adtf_dattool.exe");
            if (!File.Exists(script) || !File.Exists(tool))
                throw new FileNotFoundException("The application folder is incomplete. Keep the scripts and runtime folder beside ADTF Calibration Attachment Tool.exe.");

            var settings = new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"),
                Arguments = "-NoProfile -ExecutionPolicy RemoteSigned -STA -File \"" + script + "\"",
                WorkingDirectory = folder,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardError = true
            };
            using (Process child = Process.Start(settings))
            {
                string errors = child.StandardError.ReadToEnd();
                child.WaitForExit();
                if (child.ExitCode != 0)
                    throw new InvalidOperationException(string.IsNullOrWhiteSpace(errors)
                        ? "The calibration window could not start (exit " + child.ExitCode + ")."
                        : errors.Trim());
            }
            return 0;
        }
        catch (Exception error)
        {
            MessageBox.Show(error.Message, "ADTF Calibration Attachment Tool", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}