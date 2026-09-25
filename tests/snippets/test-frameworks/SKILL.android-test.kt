enum class Theme { LIGHT, DARK }

class PreferencesManager(context: android.content.Context) {
    fun saveTheme(theme: Theme) {}
    fun getTheme(): Theme = Theme.DARK
}
