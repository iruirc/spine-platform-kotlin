@Entity(tableName = "orders")
data class OrderEntity(
    @PrimaryKey val id: String,
    @ColumnInfo(name = "placed_at") val placedAt: Long,
    @ColumnInfo(name = "total_cents", defaultValue = "0") val totalCents: Long,
)

@Dao
interface OrderDao {
    @Query("SELECT * FROM orders WHERE id = :id")
    suspend fun find(id: String): OrderEntity?
}
