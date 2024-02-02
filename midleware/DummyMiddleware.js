export function dummyMidleware(req, res, next) {
    console.log("Executing route middleware...")
    next()
}