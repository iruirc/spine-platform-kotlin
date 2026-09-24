@Entity
data class Note(@PrimaryKey val id: Long, val text: String)

@Dao
interface NoteDao {
    @Query("SELECT * FROM Note")
    fun all(): Flow<List<Note>>
}

@Database(entities = [Note::class], version = 1, exportSchema = false)
abstract class NotesDatabase : RoomDatabase() {
    abstract fun notes(): NoteDao
}
