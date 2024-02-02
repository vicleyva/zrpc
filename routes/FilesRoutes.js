import express from 'express'
import multer from 'multer'

import { uploadFile, uploadFileList } from '../controllers/FileController.js'

const router = express.Router()
const subdir = new Date().toISOString().substring(0,10);
const upload = multer({dest: `./uploads/${subdir}/`})

router.post("/",     upload.single("file"), uploadFile)
router.post("/list", upload.array("files"), uploadFileList)


export default router