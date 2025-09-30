# FlutterFlow Test Overrides Tool

This tool automates the process of downloading your latest FlutterFlow code and applying custom patches to your integration tests. This is useful for making temporary modifications to tests that would otherwise be overwritten when you update your code from FlutterFlow.

## What It Does

This tool allows you to make temporary changes to your tests, such as:

*   Ignoring certain types of errors that are not critical to your tests.
*   Replacing `pumpAndSettle` with `pump` for more control over widget rendering.
*   Adding custom setup code to your tests.

## How to Use

1.  **Place the `tools` directory at the root of your project**, alongside your `lib` and `integration_test` directories.

2.  **Provide your FlutterFlow API Token**. You can do this in one of three ways (in order of priority):
    *   **File (Recommended)**: Create a file named `.ff_token` in the `tools` directory and paste your token into it. This file is ignored by git to keep your token secure.
    *   **Environment Variable**: Set the `FLUTTERFLOW_API_TOKEN` environment variable.
    *   **Prompt**: If neither of the above is found, the script will securely prompt you to enter your token.

3.  **Open a terminal and run the appropriate script for your operating system**:

    *   **For macOS / Linux**:
        ```bash
        ./tools/run_all.sh
        ```
    *   **For Windows (PowerShell)**:
        ```powershell
        ./tools/run_all.ps1
        ```
        > **Note for Windows Users**: If you get an error that the script is not recognized, you may need to adjust your PowerShell execution policy. You can do this for the current session by running the following command first:
        > ```powershell
        > Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned
        > ```

### Dry Run

To see what changes the script will make without actually modifying any files, use the `--dry-run` flag:

*   **For macOS / Linux**:
    ```bash
    ./tools/run_all.sh --dry-run
    ```
*   **For Windows (PowerShell)**:
    ```powershell
    ./tools/run_all.ps1 -dry-run
    ```

### Verbose Mode

For more detailed output, use the `--verbose` flag:

*   **For macOS / Linux**:
    ```bash
    ./tools/run_all.sh --verbose
    ```
*   **For Windows (PowerShell)**:
    ```powershell
    ./tools/run_all.ps1 -verbose
    ```

## How It Works

The `run_all.sh` and `run_all.ps1` scripts automate the following steps:

1.  **Checks for Dependencies**: It ensures that the `flutterflow_cli` is installed.
2.  **Gets API Token**: It retrieves your API token using one of the methods described above.
3.  **Downloads Code**: It downloads the latest code from your FlutterFlow project.
4.  **Applies Patches**: It runs the `apply_ff_test_overrides.dart` script to apply the modifications defined in `ff_test_overrides.yaml`.

## How to Customize

To customize the script, you will need to modify the `tools/ff_test_overrides.yaml` file. The most common type of customization is to add or modify the `steps` to apply different modifications to your test files.

For example, to replace the first occurrence of `tester.pumpAndSettle()` with `tester.pump()` after a specific button tap, you could use the `replace_first_after_match` step:

```yaml
- replace_first_after_match:
    anchor: "await\\s+tester\\.tap\\(find\\.byKey\\(const\\s+ValueKey\\('Button_uawt'\\)\\)\\)\\s*;"
    within_lines: 8
    pattern: "await\\s+tester\\.pumpAndSettle\\s*\\(\\s*\\)\\s*;"
    replacement: "await tester.pump();"
```

Here's how this works:

*   **`anchor`**: A regular expression that identifies a specific line in the file.
*   **`within_lines`**: How many lines after the `anchor` to search for the `pattern`.
*   **`pattern`**: A regular expression that identifies the text to be replaced.
*   **`replacement`**: The string that will replace the matched `pattern`.

By modifying the `anchor`, `pattern`, and `replacement` values, you can customize the script to apply a wide variety of modifications to your test files.
