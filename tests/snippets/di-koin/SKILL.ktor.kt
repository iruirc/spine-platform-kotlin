val appModule = module { }
class OrderService { fun byId(id: String, traceId: String): String = id }
class RequestContext(val traceId: String)
