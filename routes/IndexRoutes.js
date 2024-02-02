import express from 'express'
import { index } from '../controllers/IndexController.js'
import { dummyMidleware } from '../midleware/DummyMiddleware.js'

const router = express.Router()

// Note how to pass own middleware implementation per route here
router.post("/", dummyMidleware, index)

export default router