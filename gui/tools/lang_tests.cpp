// ---------------------------------------------------------------------------
//  Runtime checks for the trilingual UI (Simplified Chinese / English / Traditional Chinese).
//
//  The shipping translation unit is included directly, so these tests exercise the
//  real UiText() call sites, the real language settings code and the real About text.
//  No printer, driver or port operation is performed.
//
//  Build & run: tools\run_tests.bat
// ---------------------------------------------------------------------------
#define wWinMain prteasybak_program_entry
#include "../PrtEasyBAK.cpp"
#undef wWinMain

#include "lang_tests_cases.h"

#include <cstdarg>
#include <cstdio>
#include <string>

static int g_checks = 0;
static int g_failures = 0;

static void Check(bool condition, const char* format, ...) {
    ++g_checks;
    if (condition) {
        return;
    }

    ++g_failures;
    std::printf("FAIL: ");
    va_list args;
    va_start(args, format);
    std::vprintf(format, args);
    va_end(args);
    std::printf("\n");
}

// ASCII-safe rendering of a wide string, so console output never depends on the code page.
static std::string Ascii(const std::wstring& text) {
    std::string out;
    char buffer[16] = {};
    for (const wchar_t ch : text) {
        if (ch >= 32 && ch < 127) {
            out += static_cast<char>(ch);
        } else {
            std::snprintf(buffer, sizeof(buffer), "\\u%04X", static_cast<unsigned>(ch));
            out += buffer;
        }
    }
    return out;
}

static bool Contains(const std::wstring& text, const wchar_t* needle) {
    return text.find(needle) != std::wstring::npos;
}

// Detects U+FFFD (the classic mojibake marker) and unpaired surrogates.
static bool HasInvalidCodeUnit(const std::wstring& text) {
    for (std::size_t i = 0; i < text.size(); ++i) {
        const wchar_t ch = text[i];
        if (ch == 0xFFFD) {
            return true;
        }
        if (ch >= 0xD800 && ch <= 0xDBFF) {
            if (i + 1 < text.size() && text[i + 1] >= 0xDC00 && text[i + 1] <= 0xDFFF) {
                ++i;
                continue;
            }
            return true;
        }
        if (ch >= 0xDC00 && ch <= 0xDFFF) {
            return true;
        }
    }
    return false;
}

static void TestUiTextTable() {
    const AppLanguage languages[] = {
        AppLanguage::SimplifiedChinese,
        AppLanguage::English,
        AppLanguage::TraditionalChinese
    };
    int simplifiedDiffersFromEnglish = 0;

    for (const AppLanguage language : languages) {
        g_appLanguage = language;
        for (int i = 0; i < kUiTextCaseCount; ++i) {
            const UiTextCase& item = kUiTextCases[i];
            Check(item.english && *item.english, "line %d: empty English text", item.line);
            Check(item.traditional && *item.traditional, "line %d: empty Traditional Chinese text", item.line);
            Check(item.simplified && *item.simplified, "line %d: empty Simplified Chinese text", item.line);
            Check(!HasInvalidCodeUnit(item.english ? item.english : L"") &&
                      !HasInvalidCodeUnit(item.traditional ? item.traditional : L"") &&
                      !HasInvalidCodeUnit(item.simplified ? item.simplified : L""),
                  "line %d: text contains U+FFFD or an unpaired surrogate", item.line);

            const wchar_t* expected = item.english;
            if (language == AppLanguage::SimplifiedChinese) {
                expected = item.simplified;
            } else if (language == AppLanguage::TraditionalChinese) {
                expected = item.traditional;
            }

            const wchar_t* actual = UiText(item.english, item.traditional, item.simplified);
            if (std::wcscmp(actual, expected) != 0) {
                Check(false, "line %d: UiText returned the wrong text", item.line);
            }
        }
    }

    g_appLanguage = AppLanguage::SimplifiedChinese;
    for (int i = 0; i < kUiTextCaseCount; ++i) {
        const UiTextCase& item = kUiTextCases[i];
        if (std::wcscmp(item.simplified, item.english) != 0) {
            ++simplifiedDiffersFromEnglish;
        }
    }
    Check(simplifiedDiffersFromEnglish >= 60,
          "at least 60 call sites are really translated (found %d)",
          simplifiedDiffersFromEnglish);

    std::printf("  call sites checked: %d in 3 languages\n", kUiTextCaseCount);
}

static void TestFallback() {
    g_appLanguage = AppLanguage::SimplifiedChinese;
    Check(std::wcscmp(UiText(L"Fallback text", L"", L""), L"Fallback text") == 0,
          "Simplified Chinese: empty entries fall back to English");
    Check(std::wcscmp(UiText(L"Fallback text", L"\u5099\u63f4", nullptr), L"Fallback text") == 0,
          "Simplified Chinese: null entry falls back to English");

    g_appLanguage = AppLanguage::TraditionalChinese;
    Check(std::wcscmp(UiText(L"Fallback text", L"", L"\u5907\u63f4"), L"Fallback text") == 0,
          "Traditional Chinese: empty entry falls back to English");

    g_appLanguage = AppLanguage::English;
    Check(std::wcscmp(UiText(L"Fallback text", L"\u5099\u63f4", L"\u5907\u63f4"), L"Fallback text") == 0,
          "English returns English");
    Check(std::wcscmp(UiText(nullptr, nullptr, nullptr), L"") == 0,
          "null English returns an empty string instead of a dangling pointer");
}

static void TestFontsAndDetection() {
    Check(CanRenderSimplifiedChinese(), "a Simplified Chinese capable UI font is available");

    ApplyLanguageSetting(L"zh-CN");
    Check(g_appLanguage == AppLanguage::SimplifiedChinese, "zh-CN selects Simplified Chinese");
    Check(!g_uiFontFace.empty(), "a UI font face is selected for Simplified Chinese");
    std::printf("  Simplified Chinese UI font: %s\n", Ascii(g_uiFontFace).c_str());

    ApplyLanguageSetting(L"zh-TW");
    Check(g_appLanguage == AppLanguage::TraditionalChinese, "zh-TW selects Traditional Chinese");
    std::printf("  Traditional Chinese UI font: %s\n", Ascii(g_uiFontFace).c_str());

    ApplyLanguageSetting(L"en");
    Check(g_appLanguage == AppLanguage::English, "en selects English");
    std::printf("  English UI font: %s\n", Ascii(g_uiFontFace).c_str());
}

static void TestFreshInstallDefaultsToSimplifiedChinese() {
    std::error_code error;
    fs::remove(g_configPath, error);
    Check(!fs::exists(g_configPath, error), "test starts without a settings file");

    EnsureConfigIniExists();
    const std::wstring text = ReadTextFile(g_configPath);
    Check(Contains(text, L"ui_lang=zh-CN"), "a fresh PrtEasyBAK.ini defaults to ui_lang=zh-CN");

    ApplyLanguageSetting(ReadIniLanguageSetting(g_configPath));
    Check(g_appLanguage == AppLanguage::SimplifiedChinese,
          "a fresh installation starts in Simplified Chinese");
}

static void TestSwitchAndPersistAcrossRestart() {
    struct Case { AppLanguage language; const wchar_t* stored; };
    const Case cases[] = {
        { AppLanguage::SimplifiedChinese, L"ui_lang=zh-CN" },
        { AppLanguage::English, L"ui_lang=en" },
        { AppLanguage::TraditionalChinese, L"ui_lang=zh-TW" }
    };

    for (const Case& item : cases) {
        ApplyLanguageSetting(LanguageSettingValue(item.language)); // same call SwitchLanguage() makes
        Check(g_appLanguage == item.language, "applying %s selects the language", Ascii(item.stored).c_str());

        SaveLanguageSettingToIni();
        Check(Contains(ReadTextFile(g_configPath), item.stored), "%s was written to PrtEasyBAK.ini",
              Ascii(item.stored).c_str());

        // Simulate a restart: drop the in-memory value and reload from disk.
        g_appLanguage = AppLanguage::English;
        ApplyLanguageSetting(ReadIniLanguageSetting(g_configPath));
        Check(g_appLanguage == item.language, "%s survives a restart", Ascii(item.stored).c_str());
    }
}

static void TestSaveKeepsOtherSettings() {
    WriteUtf8File(g_configPath, L"; PrtEasyBAK settings\r\nsome_other_key=1\r\nui_lang=en\r\n");

    g_appLanguage = AppLanguage::SimplifiedChinese;
    SaveLanguageSettingToIni();
    const std::wstring text = ReadTextFile(g_configPath);

    Check(Contains(text, L"some_other_key=1"), "saving the language keeps unrelated settings");
    Check(Contains(text, L"ui_lang=zh-CN"), "saving the language updates ui_lang in place");
    Check(!Contains(text, L"ui_lang=en"), "the previous ui_lang value is replaced, not duplicated");
}

static void TestLegacyAndAliasValues() {
    struct Case { const wchar_t* value; AppLanguage expected; const char* note; };
    const Case cases[] = {
        // Legacy meanings must not change for existing users.
        { L"zh-TW",      AppLanguage::TraditionalChinese, "legacy zh-TW" },
        { L"zh-tw",      AppLanguage::TraditionalChinese, "legacy zh-tw" },
        { L"zh-Hant",    AppLanguage::TraditionalChinese, "legacy zh-Hant" },
        { L"zh-HK",      AppLanguage::TraditionalChinese, "legacy zh-HK" },
        { L"tw",         AppLanguage::TraditionalChinese, "legacy tw" },
        { L"cht",        AppLanguage::TraditionalChinese, "legacy cht" },
        { L"traditional",AppLanguage::TraditionalChinese, "legacy traditional" },
        { L"zh",         AppLanguage::TraditionalChinese, "legacy bare zh keeps Traditional Chinese" },
        { L"en",         AppLanguage::English,            "legacy en" },
        { L"en-US",      AppLanguage::English,            "legacy en-US" },
        { L"english",    AppLanguage::English,            "legacy english" },
        // New Simplified Chinese values.
        { L"zh-CN",      AppLanguage::SimplifiedChinese,  "new zh-CN" },
        { L"zh-cn",      AppLanguage::SimplifiedChinese,  "new zh-cn" },
        { L"zh-Hans",    AppLanguage::SimplifiedChinese,  "new zh-Hans" },
        { L"zh-SG",      AppLanguage::SimplifiedChinese,  "new zh-SG" },
        { L"cn",         AppLanguage::SimplifiedChinese,  "new cn" },
        { L"chs",        AppLanguage::SimplifiedChinese,  "new chs" },
        { L"simplified", AppLanguage::SimplifiedChinese,  "new simplified" }
    };

    for (const Case& item : cases) {
        WriteUtf8File(g_configPath, std::wstring(L"ui_lang=") + item.value + L"\r\n");
        ApplyLanguageSetting(ReadIniLanguageSetting(g_configPath));
        Check(g_appLanguage == item.expected, "%s selects the expected language", item.note);
    }

    const wchar_t* keys[] = { L"lang", L"language", L"ui_lang" };
    for (const wchar_t* key : keys) {
        WriteUtf8File(g_configPath, std::wstring(key) + L"=zh-CN\r\n");
        ApplyLanguageSetting(ReadIniLanguageSetting(g_configPath));
        Check(g_appLanguage == AppLanguage::SimplifiedChinese, "key alias %s is still honoured",
              Ascii(key).c_str());
    }

    WriteUtf8File(g_configPath, L"ui_lang=auto\r\n");
    ApplyLanguageSetting(ReadIniLanguageSetting(g_configPath));
    Check(g_appLanguage == DetectSystemLanguage(), "auto follows the system language");

    WriteUtf8File(g_configPath, L"ui_lang=not-a-language\r\n");
    ApplyLanguageSetting(ReadIniLanguageSetting(g_configPath));
    Check(g_appLanguage == DetectSystemLanguage(), "an unknown value falls back to system detection");
}

static void TestAboutText() {
    g_appLanguage = AppLanguage::SimplifiedChinese;
    const std::wstring simplified = BuildAboutText();
    Check(Contains(simplified, L"\u6253\u5370\u673a\u5907\u4efd\u4e0e\u6062\u590d\u5de5\u5177"),
          "About: Simplified Chinese title present");
    Check(!HasInvalidCodeUnit(simplified), "About: Simplified Chinese has no invalid code units");

    g_appLanguage = AppLanguage::TraditionalChinese;
    const std::wstring traditional = BuildAboutText();
    Check(Contains(traditional, L"\u5370\u8868\u6a5f"), "About: Traditional Chinese title present");
    Check(!HasInvalidCodeUnit(traditional), "About: Traditional Chinese has no invalid code units");

    g_appLanguage = AppLanguage::English;
    const std::wstring english = BuildAboutText();
    Check(Contains(english, L"Utility"), "About: English title present");
    Check(!HasInvalidCodeUnit(english), "About: English has no invalid code units");

    for (const std::wstring* text : { &simplified, &traditional, &english }) {
        Check(Contains(*text, L"v1.2.0.0"), "About: version string preserved");
        Check(Contains(*text, L"Terence0816"), "About: original author preserved");
        Check(Contains(*text, L"MIT License"), "About: licence preserved");
        Check(Contains(*text, L"PrinterBackup"), "About: backup folder name preserved");
    }

    Check(simplified != traditional && traditional != english && simplified != english,
          "About: the three languages produce different text");
}

static void TestComboAndSettingMapping() {
    Check(LanguageComboIndex(AppLanguage::SimplifiedChinese) == 0, "combo index 0 is Simplified Chinese (default)");
    Check(LanguageComboIndex(AppLanguage::English) == 1, "combo index 1 is English");
    Check(LanguageComboIndex(AppLanguage::TraditionalChinese) == 2, "combo index 2 is Traditional Chinese");

    for (int index = 0; index < 3; ++index) {
        Check(LanguageComboIndex(LanguageFromComboIndex(index)) == index, "combo index %d round-trips", index);
    }

    Check(std::wcscmp(LanguageSettingValue(AppLanguage::SimplifiedChinese), L"zh-CN") == 0,
          "Simplified Chinese is stored as zh-CN");
    Check(std::wcscmp(LanguageSettingValue(AppLanguage::English), L"en") == 0, "English is stored as en");
    Check(std::wcscmp(LanguageSettingValue(AppLanguage::TraditionalChinese), L"zh-TW") == 0,
          "Traditional Chinese is stored as zh-TW");
}

int main() {
    // Keep every settings write inside the test directory.
    std::error_code error;
    const fs::path testDirectory = fs::temp_directory_path() / L"PrtEasyBAK_lang_tests";
    fs::create_directories(testDirectory, error);
    g_configPath = testDirectory / L"PrtEasyBAK.ini";

    std::printf("PrtEasyBAK language tests\n");
    std::printf("settings file: %s\n\n", Ascii(g_configPath.wstring()).c_str());

    const struct { const char* name; void (*function)(); } suites[] = {
        { "UiText translation table (all call sites x 3 languages)", TestUiTextTable },
        { "missing translation falls back to English",              TestFallback },
        { "CJK font selection and system detection",                TestFontsAndDetection },
        { "fresh install defaults to Simplified Chinese",           TestFreshInstallDefaultsToSimplifiedChinese },
        { "language switch is saved and survives a restart",        TestSwitchAndPersistAcrossRestart },
        { "saving the language keeps other settings",               TestSaveKeepsOtherSettings },
        { "legacy and alias ui_lang values",                        TestLegacyAndAliasValues },
        { "About text in three languages",                          TestAboutText },
        { "combo index <-> language mapping",                       TestComboAndSettingMapping }
    };

    for (const auto& suite : suites) {
        const int before = g_failures;
        suite.function();
        std::printf("[%s] %s\n", g_failures == before ? "PASS" : "FAIL", suite.name);
    }

    std::printf("\n%d checks, %d failures\n", g_checks, g_failures);
    std::printf("%s\n", g_failures == 0 ? "RESULT: PASS" : "RESULT: FAIL");
    return g_failures == 0 ? 0 : 1;
}
